#!/usr/bin/env ruby

# this tool is similar to "git bisect" one, but for specs.
# it tries to find what spec from list of specs breaks execution of one specified spec.
#
# see more at http://zed.0xff.me/2010/01/28/rspec-bisect

$rspec_runner = './script/spec'
$target       = nil
$shuffle      = false
$use_fork     = false
$reverse      = false

require 'optparse'

op = OptionParser.new do |opts|
  opts.banner = "Usage: bisect.rb [options] [specs] [target_spec]"

  opts.on("-r", "--runner PATHNAME", "Use specified rspec runner (default: #{$rspec_runner})") do |arg|
    $rspec_runner = arg
  end
  opts.on("-t", "--target TARGET", "Specify target spec (default: last argument)") do |arg|
    $target = arg
  end
  opts.on("-s", "--shuffle", "Shuffle specs before running them (default: sort by name)") do
    $shuffle = true
  end
  opts.on("-R", "--reverse", "Run examples in reverse order") do
    $reverse = true
  end
  opts.on("-f", "--fork", "use fork() to eliminate loading of Rails environment each time (default: no)") do
    $use_fork = true
  end
end
op.parse!

specs = ARGV

if specs.size < 2
  puts "please give me at least 2 specs!"
  puts op
  exit
end

# TODO: warnings

target = $target || specs.pop
specs.delete(target)
specs.delete("./#{target}")
specs.delete(target.sub(/^\.\//,''))
if $shuffle
  specs.shuffle!
else
  specs.sort!
end
specs.reverse! if $reverse
puts "[.] rspec runner: #{$rspec_runner}"
puts "[.] target spec : #{target}"
puts "[.] #{specs.size} candidate specs"

if $use_fork
  puts "[.] preloading Rails environment.."
  ENV["RAILS_ENV"] ||= 'test'
  require File.expand_path(File.join(File.dirname(__FILE__),'..','config','environment'))

  require 'spec'

  module Spec::Runner
    class << self
      def autorun
        # stub to disable std rspec at_exit handler
      end
    end
  end

  @tmpfile = "tmp/rspec_bisect.#{$$}.tmp"
  File.open(@tmpfile,'w'){} # create file
  at_exit do
    # protect from accidents
    File.unlink(@tmpfile) if @tmpfile =~ /^tmp\/rspec_bisect\.\d+\.tmp$/
  end
end

def run_here specs, target
  `#{$rspec_runner} #{specs.join(' ')} #{target}`
end

def run_forked specs, target
  pid = fork do
    Object.send(:remove_const,'ARGV')
    Object.const_set('ARGV', specs + [target])
    $stdout = $stderr = File.open(@tmpfile,'w')
    begin
      ::Spec::Runner::run
    rescue SystemExit
      Process.exit!($!.status)
    rescue
      Process.exit!(-1)
    end
    Process.exit!(0)
  end
  Process.wait(pid)
  File.read(@tmpfile)
end

def run_specs target, specs
#  puts "./script/spec #{specs.join(' ')} #{target}"
  printf "[.] running %4d specs.. ", specs.size+1
  STDOUT.flush
  t0 = Time.now
  t = $use_fork ? run_forked(specs,target) : run_here(specs,target)
  r = false
  if t["#{target}:"]
    lines = t.strip.split("\n")
    lines.each_with_index do |line,idx|
      if line["#{target}:"] && idx>0 && !lines[idx-1]['(Not Yet Implemented)']
        r = true
        break
      end
    end
  end
  counts = t[/^\d+ examples, .*$/].to_s.strip.gsub(/[a-z,]/,'').strip.gsub(/ +/,"/")
#  puts "Done. (#{(Time.now - t0).to_i}s) (#{counts})\t: target #{r ? 'OK' : 'FAIL'}"
  printf("Done. (%3ds) (%s)\t: target %s\n",
    (Time.now - t0).to_i,
    counts,
    r ? 'FAIL' : 'OK'
  )
  r
end

def process_candidates target, specs
  if specs.size <= 1
    puts "[*] found matching spec: #{specs.first}"
    exit
  else
    if run_specs target, specs[0...specs.size/2]
      process_candidates target, specs[0...specs.size/2]
    elsif run_specs target, specs[specs.size/2..-1]
      process_candidates target, specs[specs.size/2..-1]
    else
      puts "[?] all specs ran OK"
#      run_specs target, specs
    end
  end
end

process_candidates target, specs
