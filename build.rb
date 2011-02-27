require 'json'
require 'tmpdir'
require 'fileutils'
require 'uri'
require 'erb'
require 'open3'

def build(package)
  puts "--- Building #{package}".green

  config = JSON.parse(File.open(File.join(package, 'config.json')).read())

  source_dir  = File.expand_path(package)

  work_dir    = File.join(Dir.tmpdir, 'pkgbuild')
  package_dir = File.join(work_dir, package)
  archive_dir = File.join(work_dir, 'archives')

  # Clean out old build directory
  if File.directory?(package_dir)
    puts " -- Removing old files"
    FileUtils.rm_rf(package_dir)
  end

  # Create temprary directories
  FileUtils.mkdir_p(package_dir)
  FileUtils.mkdir_p(archive_dir)

  config['dists'].each do |dist|
    puts " -- Building for #{dist}".green

    extract_dir = nil

    # FIXME
    git_rev = nil
    git_id = nil

    # Fetch source code
    config['sources'].each do |source|
      source_type = source['type']
      case source_type
      when 'http':
        source_url = source['url']

        uri       = URI::parse(source_url)
        filename  = File.join(archive_dir, File.basename(uri.path))

        unless File.exists?(filename)
          run_command("wget #{source_url} --directory-prefix=#{archive_dir}")
        else
          puts "  - #{filename} already downloaded."
        end

        dest = !!source['extract_to'] ? File.join(package_dir, source['extract_to']) : package_dir

        # FIXME: Need to just tell this where to extract to.
        old  = Dir.pwd
        FileUtils.cd dest
        run_command("tar zxvf #{filename}")
        FileUtils.cd(old)
      
        extract_dir = File.expand_path(Dir[File.join(package_dir, '*')].find { |f| File.directory?(f) })
    
      when 'git':
        source_url = source['url']
        extract_dir = File.join(package_dir, package)
        run_command("git clone #{source_url} #{extract_dir}")

        git_dir = File.join(extract_dir, '.git')

        git_rev = run_command("git --git-dir=#{git_dir} rev-list HEAD | wc -l | sed \"s/[ \\t]//g\"").strip
        git_id  = run_command("git --git-dir=#{git_dir} rev-list HEAD^!").strip

        puts "Got GIT REV: #{git_rev} AND ID: #{git_id}"
      else
       raise "Unknown source type #{source_type}"
      end
    end

    debian_dir = File.join(extract_dir, 'debian')

    if File.directory?(debian_dir)
      puts "  - Removing existing debian files"
      FileUtils.rm_rf(debian_dir)
    end

    puts "  - Copying debian files"
    
    FileUtils.cp_r(File.join(source_dir, 'debian'), debian_dir)

    puts "  - Creating changelog"

    name    = package
    version = git_rev ? eval('"' + config['version'] + '"') : config['version']
    message = git_id ? "Automatic package for commit #{git_id}" : 'Automatic package'
    author  = 'Eric Butler'
    email   = 'eric@codebutler.com'
    date    = Time.now.strftime('%a, %d %b %Y %H:%M:%S %z')

    template  = ERB.new CHANGELOG_ERB
    changelog = template.result(binding)

    File.open(File.join(debian_dir, 'changelog'), 'w') { |f| f.write(changelog) }

    # Build source package
    FileUtils.cd(extract_dir)
    run_command("debuild -S -sa")

    # Build binary package
    dscfile = File.join(package_dir, "#{package}_#{version}.dsc")
    run_command("pbuilder-dist #{dist} build #{dscfile}")
  end
end

def run_command(command)
  puts "  - Running #{command}"

  output = `#{command}`

  unless $? == 0
    output.lines.each do |line|
      puts "  - Error: #{line.rstrip}".red
    end
    raise "Command failed!"
  end

  output
end

CHANGELOG_ERB = <<-'EOF'
<%= name %> (<%= version %>) <%= dist %>; urgency=low

  <%= message %>

 -- <%= author %> <<%= email %>>  <%= date %>
EOF

class String
  # colorize functions
  def red; colorize(self, "\e[1m\e[31m"); end
  def green; colorize(self, "\e[1m\e[32m"); end
  def dark_green; colorize(self, "\e[32m"); end
  def yellow; colorize(self, "\e[1m\e[33m"); end
  def blue; colorize(self, "\e[1m\e[34m"); end
  def dark_blue; colorize(self, "\e[34m"); end
  def pur; colorize(self, "\e[1m\e[35m"); end
  def colorize(text, color_code) "#{color_code}#{text}\e[0m" ; end
end

build(ARGV[0])
