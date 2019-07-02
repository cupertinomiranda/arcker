require 'json'

PWD = Dir.pwd
LocalPath = "#{PWD}/.arcker"
LocalConfig = "#{PWD}/.arcker/config.json"
LocalSources = "#{PWD}/sources"

MainREPO = "git@github.com:cupertinomiranda/arcker_core.git"
MainREPOHTTPS = "https://github.com/cupertinomiranda/arcker_core.git"
ArckerConfigDir = "#{ENV['HOME']}/.arcker"
ConfigPath = "#{ArckerConfigDir}/config"
GITBareRepo = "#{ArckerConfigDir}/lib"
EDITOR = ENV["EDITOR"] || "vim"

class OptionParser
  def initialize
    @rules = {}
    @default = nil
  end
  def rule(pattern, &action)
    @rules[pattern] = action
  end

  def default(&action)
    @default_action = action
  end

  def self.match_rule(rule, args, splitter = " ", totally = true)
    opts = {}
    j = 0
    rule.split(splitter).each_with_index do |r, i|
      if(r =~ /^{([^}]+)}$/)
	flag_rules = $1.split("|")
	while(args[j] =~ /^(-[a-z]$)/)
	  flag_opt = nil
	  flag_rules.each do |flag_rule|
	    flag_opt ||= self.match_rule(flag_rule, args[j..-1], ":", false)
	  end
	  if(flag_opt)
	    opts[args[j]] = flag_opt
	    j += flag_opt.keys.length
	  else
	    return nil
	  end
	  j += 1
	end
	j -= 1
      elsif(r =~ /^<([a-z_]+)>$/)
        opts[$1] = args[j]
      elsif(r =~ /^-?[a-z_]+$/ && r == args[j])
        # Do nothing
      else
	opts = nil
	break;
      end

      j += 1
    end

    if(totally && j < args.count)
      opts = nil
    end

    return opts
  end

  def match_rules(args)
    @rules.each_pair do |rule, action|
      opts = OptionParser.match_rule(rule, args)
      if(opts != nil)
	ret = {action: action, opts: opts}
	return ret
      end
    end
    return nil
  end

  def parse(args)
    rule = match_rules(args)
    if(rule)
      rule[:action].call(rule[:opts])
    else
      @default_action.call() if (@default_action)
      exit -1
    end
  end
end

module Sys
  def _parse_cmd(command)
    cmd = ""
    if(command.kind_of?(String))
      cmd = "#{command}"
    elsif(command.kind_of?(Array))
      cmd = "#{command.join(" && ")}"
    end
    return cmd
  end
  def cmd(command)
    cmd = _parse_cmd(command)
    puts "Executing: #{cmd}"
    return `#{cmd}`
  end
  def system_cmd(command, silent = false)
    cmd = _parse_cmd(command)
    puts "System Executing: #{cmd}"
    ret = system("#{cmd}#{silent == true ? " 2> /dev/null > /dev/null" : ""}")
    return ret
  end

  def bad_usage(msg)
    puts msg
    help()
  end
  def error(msg)
    puts msg
    exit -1
  end
  def debug(msg, level=0)
    puts msg
  end

  def edit_content(str, extension="sh")
    tmp_file = "/tmp/arcker_content.#{extension}"
    cmd("echo -n '#{str}' | cat > #{tmp_file}")
    system_cmd("#{EDITOR} #{tmp_file}")
    ret = File.read(tmp_file)
    cmd("rm -f #{tmp_file}")
    return ret
  end
end

include Sys

class GIT
  def self.valid_repo(repo)
    ret = system_cmd("git ls-remote #{repo}")
    return ret
  end
end

module JSONCollector

  def self.included(klass)
    klass.extend(ClassMethods)
  end

  module ClassMethods
    def self.extended(base)
      base.instance_eval { @@elements = {} }
    end

    def elements
      @elements || []
    end

    def to_json
      JSON.pretty_generate(@elements)
    end
    def to_h
      ret = {}
      @elements.each_pair do |name, elem|
        ret[name] = elem.to_h
      end
      return ret
    end
    def from_hash(content)
      content = content || {}
      ret = {}
      content.each_pair do |k, cnt|
        ret[k] = self.new(k, cnt)
      end
      @elements = ret
      return ret
    end
    def parse(json_str)
      content = JSON.parse(json_str)
      return self.from_hash(content)
    end
    def exists?(name)
      @elements[name] != nil
    end

    def add(name, content)
      error "#{self.class} #{name} already exists." if(self.exists?(name))
      elem = self.new(name, content)
      to_add = true
      to_add &= elem.on_add_pre_validation if defined? elem.on_add_pre_validation
      error "#{self.class} #{name} failed to validate" if(!elem.validate)
      to_add &= elem.on_add_post_validation if defined? elem.on_add_post_validation
      if(to_add)
	@elements[name] = elem
	ARCKER.instance.save
	return @elements[name]
      else
	return nil
      end
    end

    def remove(name)
      elem = @elements[name]
      elem.on_remove if defined? elem.on_remove
      @elements.delete(name)
      ARCKER.instance.save
    end
    def get(name, report = true)
      elem = @elements[name]
      error "Could not find #{self} with name #{name}." if (elem == nil && report)
      return elem
    end

    def list
      @elements.keys
    end

    def all
      @elements.values
    end
  end

  def with_name(name)
    @@elements[name]
  end

end


class Source
  include JSONCollector

  def initialize(name, content = {})
    @name = name
    @repo = content["repo"]
  end

  def to_h
    { "repo" => @repo }
  end

  def central_dir
    repo_name = ARCKER.instance.repo_name
    "#{GITBareRepo}/#{repo_name}/#{@name}"
  end

  def local_dir
    "#{LocalSources}/#{@name}"
  end

  def validate
    error "GIT repo #{@repo} not found." if !GIT.valid_repo(@repo)
    return true
  end
  def on_add_post_validation
    self.download
  end
  def on_remove
    self.delete_source
  end

  def download()
    if(!File.exists?(central_dir))
      Sys.cmd("mkdir -p #{central_dir} && git clone --mirror #{@repo} #{central_dir}")
    end
    if(!File.exists?(local_dir))
      cmd("mkdir -p #{local_dir}")
      branch_name = "#{@name}_#{PWD.gsub("/", "_")}"
      Sys.cmd("cd #{central_dir} && git worktree prune && git worktree add -b #{branch_name} #{local_dir}")
    end
  end
  def delete_source
    if(File.exists?(local_dir))
      cmd("rm -rf #{local_dir}")
      cmd("rm -rf #{central_dir(name)}")
      cmd("cd #{central_dir} && git worktree prune")
    end
  end
  def self.get_sources
    elements.each_pair do |name, source|
      source.download
    end
  end
end

class Task
  def new_tas_code
    return <<STR_END
#!/bin/bash
# Code for task #{name}.
#
# Persistent: false
# DependsOn:
# Vars:
#
# Please edit this file to execute the desired operation.
# Return 0 for success != 0 for fail.
# The return value determines when persistency is satifiable.

exit 0
STR_END
  end

  include JSONCollector

  attr_reader :name

  def initialize(name, content = {})
    @name = name
    @code = content["code"]
    @dirty = content["dirty"] != nil ? content["dirty"] : true
    @vars = nil
  end

  def to_h
    { "code" => @code, "dirty" => @dirty }
  end

  def depends_on(report_error = false)
    ret = []
    non_valid = []
    @code.split("\n").each do |line|
      if(line =~ /DependsOn:([^\n]+)/)
	$1.split(/[ \t,;]+/).select { |a| a =~ /^[^ \t]+$/ }.each do |task_name|
	  if((task = Task.get(task_name, false)) != nil)
	    ret.push(task)
	  elsif(report_error)
	    non_valid.push(task_name)
	  end
	end
      end
    end
    puts non_valid
    if(report_error && non_valid.length > 0)
      error "DependsOn has inexistant tasks: #{non_valid.join(", ")}"
    end
    return ret
  end

  def dependents
    ret = []
    Task.all.select do |task|
      task.depends_on.each { |t1| ret.push(task) if t1 == self }
    end
    return ret
  end

  def self.required_vars
    ret = []
    Task.elements.each_pair do |name, task|
      ret += task.vars
    end
    return ret
  end

  def vars()
    return @vars if @vars
    ret = []
    @code.split("\n").each do |line|
      if(line =~ /Vars:([^\n]+)/)
	$1.split(/[ \t,;]+/).each do |var_name|
	  ret.push(var_name) if(var_name !~ /^[ \t]*$/)
	end
      end
    end
    @vars = ret
    return ret
  end

  def has_variable?(var)
    vars.index(var) != nil
  end

  def persistent?
    return true if(@code =~ /Persistent:[ \t]+true/)
    return false
  end

  def validate
    depends_on(true)
    return true
  end

  def on_add_pre_validation
    @code = new_tas_code
    if(!self.change)
      error "No change made to task code. Task was not created."
    end
    return true
  end

  def change
    new_code = edit_content(@code)
    if(@code != new_code)
      @code = new_code
      @vars = nil
      return true
    else
      return false
    end
  end

  def edit
    if(change)
      depends_on(true)
      trash(false)
      ARCKER.instance.save
    else
      error "No change made to task code. Task was not edited."
    end
  end

  def dirty?
    return @dirty
  end
  def trash(save = true, already_trashed = [])
    return already_trashed if already_trashed.index(@name) != nil

    @dirty = true
    already_trashed.push(@name)
    dependents.each do |task|
      already_trashed = task.trash(false, already_trashed)
    end
    ARCKER.instance.save if save
    return already_trashed
  end

  def _run_task(config, already_executed = [])
    return already_executed if already_executed.index(@name) != nil
    if @dirty == false
      already_executed.push(@name)
      return already_executed
    end

    depends_on.each do |depend|
      already_executed = depend._run_task(config, already_executed)
    end

    File.write(".run.sh", "#{config}\n. ./.current_task.sh")
    File.write(".current_task.sh", @code)
    debug("Executing task #{name}.")
    ret = system_cmd("chmod +x .run.sh && chmod +x .current_task.sh && ./.run.sh && rm -f .current_task.sh .run.sh")
    @dirty = false if(ret == true && persistent?)
    already_executed.push(@name)
    raise("Task #{name} failed to execute.") if (ret == false)
    return already_executed
  end
  def run_task(edit_config = false)
    config = Config.current(true).content
    ndv = Config.current.non_defined_vars
    error("Cannot execute task #{name}. Variables #{ndv.join(", ")} are not defined.") if(ndv.length > 0)
    config = edit_content(config) if(edit_config == true)
    begin
      _run_task(config)
    rescue StandardError => e
      debug(e)
    end
    ARCKER.instance.save
  end
end

class Config
  include JSONCollector
  @@current = nil

  def self.reset_to(config_name)
    @@current = self.get(config_name)
    ARCKER.instance.save
  end

  def self.set_current(config_content)
    @@current = self.new("_", config_content)
  end
  def self.current(fail = false)
    error("You should first create a config.") if (@@current.nil? && fail)
    @@current
  end

  attr_reader :name, :content

  def initialize(name, content = {})
    @name = name
    @content = content
  end

  def to_h
    @content
  end

  def vars()
    ret = []
    @content.split("\n").each do |line|
      if(line =~ /([A-Za-z][A-Za-z0-9_]+)=[^\n;]*/)
	ret.push($1)
      end
    end
    return ret
  end
  def non_defined_vars
    content_vars = vars
    return Task.required_vars.select { |v| vars.index(v) == nil }
  end

  def validate
    return true
  end

  def evaluated_vars
    var_dump = vars.map { |n| "echo \"#{n}=${#{n}}\"" }.join("\n")
    File.write(".current_task.sh", "#{@content}\n#{var_dump}")
    result = cmd("chmod +x .current_task.sh && ./.current_task.sh && rm -f .current_task.sh")
    vars = vars()
    matches = {}
    result.split("\n").each do |a|
      if(a =~ /^([^=]+)=(.*$)/)
	matches[$1] = $2
      end
    end
    return matches
  end

  def get_different_variables(other_config)
    vars = self.evaluated_vars
    other_vars = other_config.evaluated_vars

    ret = []
    vars.each_pair { |n, v| ret.push(n) if v != other_vars[n]; puts "DIFF: #{n}" if v != other_vars[n] }
    return ret
  end

  def self.edit
    @@current ||= self.new("_", "")
    old_config = @@current.clone
    @@current.change

    diff_vars = @@current.get_different_variables(old_config)

    Task.all.each do |task|
      if(task.persistent? && !task.dirty?)
	diff_vars.each do |var|
	  task.trash(false) if task.has_variable?(var)
	end
      end
    end

    File.write(".current_task.sh", @content)
    ret = system_cmd("chmod +x .current_task.sh && ./.current_task.sh && rm -f .current_task.sh")

    if(ret)
      ARCKER.instance.save if(ret)
    else
      error("Problem executing config file.")
    end
  end

  def change
    @old_config = self.clone
    ndv = non_defined_vars
    content = @content
    content += "\n# Mising variables:\n#{ndv.map { |v| "##{v}=" }.join("\n") }" if ndv.length > 0
    new_content = edit_content(content)
    if(content != new_content)
      @content = new_content
      return true
    else
      return false
    end
  end
end

class ARCKER
  @@instance = nil

  def initialize(config_file)
    if(File.exists?(config_file))
      @config = JSON.parse(File.read(config_file))
      Task.from_hash(@config["tasks"])
      Source.from_hash(@config["sources"])
      Config.from_hash(@config["configs"])
      Config.set_current(@config["config"]) if @config["config"]
      @config.delete("tasks")
      @config.delete("sources")
      @config.delete("configs")

      @@instance = self
    else
      puts("Directory is not ARCKER initialized.")
      return nil
    end
  end

  def self.instance
    if(@@instance == nil)
      ret = self.new(LocalConfig)
      error "Not a ARCKER initialized directory" if ret == nil
      return ret
    else
      return @@instance
    end
  end

# GENERIC CODE

  def _save_config
    @config["sources"] = Source.to_h
    @config["tasks"] = Task.to_h
    @config["configs"] = Config.to_h
    @config["config"] = Config.current.content if Config.current
    File.write(LocalConfig, JSON.pretty_generate(@config))
  end
  def save
    _save_config
  end

  def repo_name
    "repo_#{@config["name"]}"
  end

# REPO related code

  def self.setup()
    Sys.system_cmd("mkdir -p #{ArckerConfigDir}")
    if(!File.exists?(ConfigPath))
      ret = Sys.system_cmd("git clone --mirror #{MainREPO} #{ConfigPath}")
      Sys.system_cmd("git clone --mirror #{MainREPOHTTPS} #{ConfigPath}") if(ret != true)
    end
  end

  def self.update
    Sys.cmd("cd #{ConfigPath} && git fetch")
    Sys.cmd("cd #{LocalPath} && git fetch")
    #Sys.cmd("cd #{ConfigPath} && git fetch #{MainREPO}")
    #Sys.cmd("cd #{LocalPath} && git fetch #{MainREPO}")
  end

  def self.list_repos
    update
    ret =  Sys.cmd("cd #{ConfigPath} && git ls-remote")
    puts ret
    repo_lines = ret.split("\n").select { |a| a =~ /^[^ \t]+[ \t]refs\/heads\/repo_/ }
    repos = repo_lines.map { |a| a =~ /repo_([^\n]+)/; $1 }
    return repos
    #return ret.split("\n").select { |a| a =~ /^[* ]+repo_/ }.map { |a| a.gsub(/^[* ]+repo_/, "") }
  end

  def self.create_repo(name, origin = "origin/master")
    repo_name = "repo_#{name}"
    if(File.exists?(LocalPath))
      error("Directory is already assign to ARCKER repo.")
    elsif(list_repos.index(name) != nil)
      error("Repo with same name already exists.")
    else
      Sys.cmd("git clone #{ConfigPath} #{LocalPath} && cd #{LocalPath} && git checkout -b #{repo_name} #{origin}")
      arcker = ARCKER.new(LocalConfig)
      arcker.instance_eval { puts @config.inspect; @config["name"] = name; File.write(LocalConfig, JSON.pretty_generate(@config)) }
    end
  end

  def self.init(name)
    repo_name = "repo_#{name}"
    if(File.exists?(LocalPath))
      error("Directory is already assign to ARCKER repo.")
    else
      Sys.cmd("git clone #{ConfigPath} #{LocalPath} && cd #{LocalPath} && git checkout #{repo_name}")
      arcker = ARCKER.new(LocalConfig)
      Source.get_sources
    end
  end

  def commit
    return Sys.system_cmd("cd #{LocalPath} && git add config.json && git commit")
  end
  def push(remote = "origin")
    commit()
    #ret = Sys.system_cmd("cd #{LocalPath} && git push --repo #{MainREPO} -u #{remote} #{repo_name}")
    #if(ret != 0)
    #  Sys.cmd("cd #{LocalPath} && git push --repo #{MainREPOHTTPS} -u #{remote} #{repo_name}")
    #end
    Sys.cmd("cd #{LocalPath} && git push -u #{remote} #{repo_name}")
    Sys.cmd("cd #{ConfigPath} && git push")
    ARCKER.update()
  end
end

arcker = ARCKER.new(LocalConfig)
opt = OptionParser.new

opt.default do
  puts "THIS IS VERY OUTDATED ... FEEL FREE TO UPDATE IT AS YOU LEARN. :D"
  puts ""
  puts "Commands:"
  puts "  init <type> - initialize repo tree"
  puts "  update - Update global ARCKER configs"
  puts "  sources <worktree_branch_name> - initialize worktree sources in new branch"
  puts "  do <task_name> - Execute task and consequent dependencies."
  puts "  plumber help - advanced control help."
  puts ""
  puts "Plumber commands:"
  puts "  plumber repo create <type> - create a new global repo tree"
  puts "  plumber repo remove <type>"
  puts "  plumber push - push local configs to global repo"
  puts "  plumber source list"
  puts "  plumber source add <name> <repo>"
  puts "  plumber source remove <name>"
  puts "  plumber task create <name>"
  puts "  plumber task edit <name>"
  puts "  plumber task remove <name>"
  puts ""
end

# RULES
#opt.rule("plumber sources add {-h:<value>|-x} <name> <gitrepo>") do |opts|
#  puts "Doing it."
#end
opt.rule("setup")	  { |opts| ARCKER.setup }
opt.rule("init <name>")   { |opts| ARCKER.init(opts["name"]) }
opt.rule("update")	  { |opts| ARCKER.update }

opt.rule("list known repos")	  { |opts| puts "Known repos: #{ARCKER.list_repos.join(" ")}" }
opt.rule("list tasks")		  { |opts| puts "Available tasks: #{Task.list.join(", ")} " }
opt.rule("list sources")  	  { |opts| puts JSON.pretty_generate(Source.to_h) }
opt.rule("list known configs")	  { |opts| puts "Available configs: #{Config.list.join(", ")} " }

opt.rule("get_sources")		  { |opts| Source.get_sources }
opt.rule("do {-e} <name>")	  { |opts| Task.get(opts["name"]).run_task(opts["-e"].nil? ? false : true) }
opt.rule("trash <name>")	  { |opts| Task.get(opts["name"]).trash }

opt.rule("config")			{ |opts| Config.edit }
opt.rule("config publish <name>")	{ |opts| Config.add(opts["name"], { content: Config.current.content }) }
opt.rule("config remove <name>")	{ |opts| Config.remove(opts["name"]) }
opt.rule("config reset <name>")		{ |opts| Config.reset_to(opts["name"]) }

opt.rule("plumber repo create <name>")	{ |opts| ARCKER.create_repo(opts["name"]) }
opt.rule("plumber repo create <name> <repo_to_copy>")	{ |opts| ARCKER.create_repo(opts["name"], opts["repo_to_copy"]) }
opt.rule("plumber repo remove <name>")	{ |opts| ARCKER.repo_remove(opts["name"]) }

opt.rule("plumber source add <name> <gitrepo>") { |opts| Source.add(opts["name"], { "repo" => opts["gitrepo"] }) }
opt.rule("plumber source remove <name>")	{ |opts| Source.remove(opts["name"]) }

opt.rule("plumber task create <name>")	{ |opts| Task.add(opts["name"], {}) }
opt.rule("plumber task remove <name>")	{ |opts| Task.remove(opts["name"]) }
opt.rule("plumber task edit <name>")	{ |opts| Task.get(opts["name"]).edit }

opt.rule("plumber push")		{ |opts| arcker.push }

opt.parse(ARGV)
