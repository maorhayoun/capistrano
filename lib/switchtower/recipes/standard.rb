# Standard tasks that are useful for most recipes. It makes a few assumptions:
# 
# * The :app role has been defined as the set of machines consisting of the
#   application servers.
# * The :web role has been defined as the set of machines consisting of the
#   web servers.
# * The Rails spinner and reaper scripts are being used to manage the FCGI
#   processes.
# * There is a script in script/ called "reap" that restarts the FCGI processes

set :rake, "rake"

desc "Enumerate and describe every available task."
task :show_tasks do
  keys = tasks.keys.sort_by { |a| a.to_s }
  longest = keys.inject(0) { |len,key| key.to_s.length > len ? key.to_s.length : len } + 2

  puts "Available tasks"
  puts "---------------"
  tasks.keys.sort_by { |a| a.to_s }.each do |key|
    desc = (tasks[key].options[:desc] || "").strip.split(/\r?\n/)
    puts "%-#{longest}s %s" % [key, desc.shift]
    puts "%#{longest}s %s" % ["", desc.shift] until desc.empty?
    puts
  end
end

desc "Set up the expected application directory structure on all boxes"
task :setup, :roles => [:app, :db, :web] do
  run <<-CMD
    mkdir -p -m 775 #{releases_path} #{shared_path}/system &&
    mkdir -p -m 777 #{shared_path}/log
  CMD
end

desc <<-DESC
Disable the web server by writing a "maintenance.html" file to the web
servers. The servers must be configured to detect the presence of this file,
and if it is present, always display it instead of performing the request.
DESC
task :disable_web, :roles => :web do
  on_rollback { delete "#{shared_path}/system/maintenance.html" }

  maintenance = render("maintenance", :deadline => ENV['UNTIL'],
    :reason => ENV['REASON'])
  put maintenance, "#{shared_path}/system/maintenance.html", :mode => 0644
end

desc %(Re-enable the web server by deleting any "maintenance.html" file.)
task :enable_web, :roles => :web do
  delete "#{shared_path}/system/maintenance.html"
end

desc <<-DESC
Update all servers with the latest release of the source code. All this does
is do a checkout (as defined by the selected scm module).
DESC
task :update_code, :roles => [:app, :db, :web] do
  on_rollback { delete release_path, :recursive => true }

  source.checkout(self)

  run <<-CMD
    rm -rf #{release_path}/log #{release_path}/public/system &&
    ln -nfs #{shared_path}/log #{release_path}/log &&
    ln -nfs #{shared_path}/system #{release_path}/public/system
  CMD
end

desc <<-DESC
Rollback the latest checked-out version to the previous one by fixing the
symlinks and deleting the current release from all servers.
DESC
task :rollback_code, :roles => [:app, :db, :web] do
  if releases.length < 2
    raise "could not rollback the code because there is no prior release"
  else
    run <<-CMD
      ln -nfs #{previous_release} #{current_path} &&
      rm -rf #{current_release}
    CMD
  end
end

desc <<-DESC
Update the 'current' symlink to point to the latest version of
the application's code.
DESC
task :symlink, :roles => [:app, :db, :web] do
  on_rollback { run "ln -nfs #{previous_release} #{current_path}" }
  run "ln -nfs #{current_release} #{current_path}"
end

desc "Restart the FCGI processes on the app server."
task :restart, :roles => :app do
  sudo "#{current_path}/script/process reaper"
end

set :migrate_target, :current
set :migrate_env, ""

desc <<-DESC
Run the migrate rake task. By default, it runs this in the version of the app
indicated by the 'current' symlink. (This means you should not invoke this task
until the symlink has been updated to the most recent version.) However, you
can specify a different release via the migrate_target variable, which must be
one of "current" (for the default behavior), or "latest" (for the latest release
to be deployed with the update_code task). You can also specify additional
environment variables to pass to rake via the migrate_env variable. Finally, you
can specify the full path to the rake executable by setting the rake variable.
DESC
task :migrate, :roles => :db, :only => { :primary => true } do
  directory = case migrate_target.to_sym
    when :current then current_path
    when :latest  then current_release
    else
      raise ArgumentError,
        "you must specify one of current or latest for migrate_target"
  end

  run "cd #{directory} && " +
      "#{rake} RAILS_ENV=production #{migrate_env} migrate"
end

desc <<-DESC
A macro-task that updates the code, fixes the symlink, and restarts the
application servers.
DESC
task :deploy do
  transaction do
    update_code
    symlink
  end

  restart
end

desc <<-DESC
Similar to deploy, but it runs the migrate task on the new release before
updating the symlink. (Note that the update in this case is not atomic,
and transactions are not used, because migrations are not guaranteed to be
reversible.)
DESC
task :deploy_with_migrations do
  update_code

  begin
    old_migrate_target = migrate_target
    set :migrate_target, :latest
    migrate
  ensure
    set :migrate_target, old_migrate_target
  end

  symlink

  restart
end

desc "A macro-task that rolls back the code and restarts the application servers."
task :rollback do
  rollback_code
  restart
end

desc <<-DESC
Displays the diff between HEAD and what was last deployed. (Not available
with all SCM's.)
DESC
task :diff_from_last_deploy do
  diff = source.diff(self)
  puts
  puts diff
  puts
end
