require 'gitolite'
require 'timeout'
require 'fileutils'

# TODO: refactor & cleanup 
module Gitlab
  class Gitolite
    class AccessDenied < StandardError; end
    class InvalidKey < StandardError; end

    def set_key key_id, key_content, projects
      configure do |c|
        c.update_keys(key_id, key_content)
        c.update_projects(projects)
      end
    end

    def remove_key key_id, projects
      configure do |c|
        c.delete_key(key_id)
        c.update_projects(projects)
      end
    end

    def update_repository project
      configure do |c|
        c.update_project(project.path, project)
      end
    end

    alias_method :create_repository, :update_repository

    def remove_repository project
      configure do |c|
        c.destroy_project(project)
      end
    end

    def url_to_repo path
      Gitlab.config.ssh_path + "#{path}.git"
    end

    def initialize
      # create tmp dir
      @local_dir = File.join(Rails.root, 'tmp',"gitlabhq-gitolite-#{Time.now.to_i}")
    end

    def enable_automerge
      configure do |git|
        git.admin_all_repo
      end
    end

    protected

    def destroy_project(project)
      FileUtils.rm_rf(project.path_to_repo)

      ga_repo = ::Gitolite::GitoliteAdmin.new(File.join(@local_dir,'gitolite'))
      conf = ga_repo.config
      conf.rm_repo(project.path)
      ga_repo.save
    end

    #update or create
    def update_keys(user, key)
      File.open(File.join(@local_dir, 'gitolite/keydir',"#{user}.pub"), 'w') {|f| f.write(key.gsub(/\n/,'')) }
    end

    def delete_key(user)
      File.unlink(File.join(@local_dir, 'gitolite/keydir',"#{user}.pub"))
      `cd #{File.join(@local_dir,'gitolite')} ; git rm keydir/#{user}.pub`
    end

    # update or create
    def update_project(repo_name, project)
      ga_repo = ::Gitolite::GitoliteAdmin.new(File.join(@local_dir,'gitolite'))
      conf = ga_repo.config
      repo = update_project_config(project, conf)
      conf.add_repo(repo, true)
      
      ga_repo.save
    end

    # Updates many projects and uses project.path as the repo path
    # An order of magnitude faster than update_project
    def update_projects(projects)
      ga_repo = ::Gitolite::GitoliteAdmin.new(File.join(@local_dir,'gitolite'))
      conf = ga_repo.config

      projects.each do |project|
        repo = update_project_config(project, conf)
        conf.add_repo(repo, true)
      end

      ga_repo.save
    end

    def update_project_config(project, conf)
      repo_name = project.path

      repo = if conf.has_repo?(repo_name)
               conf.get_repo(repo_name)
             else 
               ::Gitolite::Config::Repo.new(repo_name)
             end

      name_readers = project.repository_readers
      name_writers = project.repository_writers
      name_masters = project.repository_masters

      pr_br = project.protected_branches.map(&:name).join("$ ")

      repo.clean_permissions

      # Deny access to protected branches for writers
      unless name_writers.blank? || pr_br.blank?
        repo.add_permission("-", pr_br.strip + "$ ", name_writers)
      end

      # Add read permissions
      repo.add_permission("R", "", name_readers) unless name_readers.blank?

      # Add write permissions
      repo.add_permission("RW+", "", name_writers) unless name_writers.blank?
      repo.add_permission("RW+", "", name_masters) unless name_masters.blank?

      repo
    end

    def admin_all_repo
      ga_repo = ::Gitolite::GitoliteAdmin.new(File.join(@local_dir,'gitolite'))
      conf = ga_repo.config
      owner_name = ""

      # Read gitolite-admin user
      #
      begin 
        repo = conf.get_repo("gitolite-admin")
        owner_name = repo.permissions[0]["RW+"][""][0]
        raise StandardError if owner_name.blank?
      rescue => ex
        puts "Can't determine gitolite-admin owner".red
        raise StandardError
      end

      # @ALL repos premission for gitolite owner
      repo_name = "@all"
      repo = if conf.has_repo?(repo_name)
               conf.get_repo(repo_name)
             else 
               ::Gitolite::Config::Repo.new(repo_name)
             end

      repo.add_permission("RW+", "", owner_name)
      conf.add_repo(repo, true)
      ga_repo.save
    end

    private

    def pull
      # create tmp dir
      @local_dir = File.join(Rails.root, 'tmp',"gitlabhq-gitolite-#{Time.now.to_i}")
      Dir.mkdir @local_dir

      `git clone #{Gitlab.config.gitolite_admin_uri} #{@local_dir}/gitolite`
    end

    def push
      Dir.chdir(File.join(@local_dir, "gitolite"))
      `git add -A`
      `git commit -am "Gitlab"`
      `git push`
      Dir.chdir(Rails.root)

      FileUtils.rm_rf(@local_dir)
    end

    def configure
      Timeout::timeout(30) do
        File.open(File.join(Rails.root, 'tmp', "gitlabhq-gitolite.lock"), "w+") do |f|
          begin 
            f.flock(File::LOCK_EX)
            pull
            yield(self)
            push
          ensure
            f.flock(File::LOCK_UN)
          end
        end
      end
    rescue Exception => ex
      if ex.message =~ /is not a valid SSH key string/
        raise Gitolite::InvalidKey.new("ssh key is not valid")
      else
        Gitlab::Logger.error(ex.message)
        raise Gitolite::AccessDenied.new("gitolite timeout")
      end
    end
  end
end
