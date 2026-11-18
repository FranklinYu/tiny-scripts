# frozen_string_literal: true

require 'etc'
require 'open3'
require 'tmpdir'

RSpec.describe 'The binary “user-tmpfiles”' do
  let(:script) { File.expand_path('../libexec/user-tmpfiles', __dir__) }
  let(:root) { @root }
  let(:config_dir) { File.join(root, 'config') }
  let(:target) { File.join(root, 'target') }

  around do |example|
    Dir.mktmpdir('user-tmpfiles-spec') do |directory|
      @root = directory
      Dir.mkdir(config_dir)
      example.run
    end
  end

  def write_config(content, name = 'directories.conf')
    File.write(File.join(config_dir, name), content)
  end

  def run_script(directory = config_dir, env: {}, **options)
    Open3.capture3(env, script, directory, **options)
  end

  def expect_success(result)
    stdout, stderr, status = result
    expect(status).to be_success, "stdout: #{stdout}\nstderr: #{stderr}"
    expect(stderr).to be_empty
  end

  def mode(path)
    File.stat(path).mode & 0o7777
  end

  it 'creates missing parents and applies the requested mode despite umask' do
    nested = File.join(target, 'parent', 'child')
    write_config("d #{nested} 0750\n")

    result = run_script(umask: 0o077)

    expect_success(result)
    expect(File).to be_directory(nested)
    expect(mode(nested)).to eq(0o750)
    expect(result.first).to include(nested)
  end

  it 'accepts d$ and quoted paths with spaces and tabs' do
    double_quoted = File.join(root, 'Application Support', 'app')
    single_quoted = File.join(root, "tab\tdirectory")
    write_config(<<~CONFIG)
      d$ "#{double_quoted}" 0700 - - - -
      d '#{single_quoted}' 750
    CONFIG

    expect_success(run_script)
    expect(mode(double_quoted)).to eq(0o700)
    expect(mode(single_quoted)).to eq(0o750)
  end

  it 'uses 0755 for omitted and placeholder modes' do
    write_config(<<~CONFIG)
      d #{target}
      d #{target}/placeholder - - - - -
    CONFIG

    expect_success(run_script(umask: 0o077))
    expect(mode(target)).to eq(0o755)
    expect(mode(File.join(target, 'placeholder'))).to eq(0o755)
  end

  it 'reapplies permissions without removing existing contents when rerun' do
    Dir.mkdir(target, 0o700)
    retained = File.join(target, 'retained')
    File.write(retained, 'keep me')
    write_config("d$ #{target} 0750\n")

    2.times { expect_success(run_script) }

    expect(mode(target)).to eq(0o750)
    expect(File.read(retained)).to eq('keep me')
  end

  it 'expands account specifiers once using the effective user account' do
    account = Etc.getpwuid(Process.euid)
    write_config("d #{root}/%h/%u-%%-%%h 0700\n")

    expect_success(run_script(env: { 'HOME' => '/wrong-home', 'USER' => 'wrong-user' }))

    expanded = "#{root}/#{account.dir}/#{account.name}-%-%h"
    expect(File).to be_directory(expanded)
    expect(mode(expanded)).to eq(0o700)
  end

  it 'preserves shell metacharacters and hash characters literally' do
    literal = File.join(root, '$(touch sentinel)-$HOME-`id`-#literal')
    write_config("d \"#{literal}\" 0700\n")

    expect_success(run_script(chdir: root))

    expect(File).to be_directory(literal)
    expect(File).not_to exist(File.join(root, 'sentinel'))
  end

  it 'skips blank lines and whole-line comments' do
    write_config("\n \t\n  # ignored \\\n\td\t#{target}\t0700\n")

    expect_success(run_script)
    expect(File).to be_directory(target)
  end

  it 'reads only top-level conf files in filename order' do
    write_config("d #{target} 0700\n", '20-last.conf')
    write_config("d #{target} 0755\n", '10-first.conf')
    write_config('invalid input', 'ignored.txt')
    nested = File.join(config_dir, 'nested')
    Dir.mkdir(nested)
    File.write(File.join(nested, 'invalid.conf'), 'invalid input')

    expect_success(run_script)
    expect(mode(target)).to eq(0o700)
  end

  it 'accepts an empty configuration directory' do
    expect_success(run_script)
  end

  it 'includes a configuration file named .conf' do
    write_config("d #{target} 0700\n", '.conf')

    expect_success(run_script)
    expect(File).to be_directory(target)
  end

  it 'validates every file before creating any directories' do
    write_config("d #{target} 0700\n", '10-valid.conf')
    write_config("# comment\n\nf #{root}/invalid 0700\n", '20-invalid.conf')

    stdout, stderr, status = run_script

    expect(status).not_to be_success
    expect(stdout).to include('20-invalid.conf:3:')
    expect(stderr).to be_empty
    expect(File).not_to exist(target)
  end

  it 'does not create directories when a later file contains invalid UTF-8' do
    write_config("d #{target} 0700\n", '10-valid.conf')
    File.binwrite(File.join(config_dir, '20-invalid.conf'), "\xFF")

    stdout, stderr, status = run_script

    expect(status).not_to be_success
    expect(stdout).to include('20-invalid.conf')
    expect(stderr).to be_empty
    expect(File).not_to exist(target)
  end

  {
    'missing path' => 'd',
    'unsupported type' => 'f TARGET 0700',
    'unsupported modifier' => 'd! TARGET 0700',
    'relative path' => 'd relative/path 0700',
    'empty path' => 'd "" 0700',
    'unknown specifier' => 'd TARGET/%x 0700',
    'trailing percent' => 'd TARGET/% 0700',
    'non-octal mode' => 'd TARGET 0788',
    'symbolic mode' => 'd TARGET u=rwx',
    'mode modifier' => 'd TARGET ~0700',
    'oversized mode' => 'd TARGET 10000',
    'explicit user' => 'd TARGET 0700 root',
    'explicit group' => 'd TARGET 0700 - wheel',
    'age' => 'd TARGET 0700 - - 10d',
    'argument' => 'd TARGET 0700 - - - value',
    'extra field' => 'd TARGET 0700 - - - - -',
    'inline comment' => 'd TARGET 0700 # comment',
    'backslash escape' => 'd TARGET/with\ space 0700',
    'unterminated quote' => 'd "TARGET 0700',
    'partial quoting' => 'd TARGET/"quoted" 0700'
  }.each do |description, line|
    it "rejects #{description} with a filename and line number on stdout" do
      write_config("# comment\n\n#{line.gsub('TARGET', target)}\n")

      stdout, stderr, status = run_script

      expect(status).not_to be_success
      expect(stdout).to include('directories.conf:3:')
      expect(stderr).to be_empty
      expect(File).not_to exist(target)
    end
  end

  it 'reports a regular file at the target without altering it' do
    File.write(target, 'keep me')
    write_config("d #{target} 0700\n")

    stdout, stderr, status = run_script

    expect(status).not_to be_success
    expect(stdout).to include(target)
    expect(stderr).to be_empty
    expect(File.read(target)).to eq('keep me')
  end

  it 'reports a regular file blocking a parent directory' do
    File.write(target, 'keep me')
    write_config("d #{target}/child 0700\n")

    stdout, stderr, status = run_script

    expect(status).not_to be_success
    expect(stdout).to include(target)
    expect(stderr).to be_empty
    expect(File.read(target)).to eq('keep me')
  end

  it 'reports a missing configuration directory on stdout' do
    missing = File.join(root, 'missing')

    stdout, stderr, status = run_script(missing)

    expect(status).not_to be_success
    expect(stdout).to include(missing)
    expect(stderr).to be_empty
    expect(File).not_to exist(missing)
  end

  it 'shows help on stdout' do
    stdout, stderr, status = Open3.capture3(script, '--help')

    expect(status).to be_success
    expect(stdout).to include('user-tmpfiles')
    expect(stderr).to be_empty
  end

  it 'reports invalid command-line options on stdout' do
    stdout, stderr, status = Open3.capture3(script, '--unknown')

    expect(status).not_to be_success
    expect(stdout).to include('--unknown')
    expect(stderr).to be_empty
  end
end
