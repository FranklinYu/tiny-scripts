# frozen_string_literal: true

require 'open3'
require 'tmpdir'

RSpec.describe 'The binary “git-format-message”' do
  let(:script) { File.expand_path('../libexec/git-format-message', __dir__) }
  let(:root) { @root }
  let(:message_file) { File.join(root, 'commit message') }
  let(:unformatted_body) do
    "Use the\ncached result\n" \
      "when the input is unchanged so callers can skip parsing the same document twice.\n"
  end
  let(:formatted_body) do
    "Use the cached result when the input is unchanged so callers can skip\n" \
      "parsing the same document twice.\n"
  end

  around do |example|
    Dir.mktmpdir('git-format-message-spec') do |directory|
      @root = directory
      example.run
    end
  end

  def run_script(*arguments, input: '')
    env = {
      'GIT_CONFIG_GLOBAL' => File::NULL,
      'GIT_CONFIG_NOSYSTEM' => '1'
    }
    Open3.capture3(env, script, *arguments, stdin_data: input, chdir: root)
  end

  def expect_success(result)
    stdout, stderr, status = result
    expect(status).to be_success, "stdout: #{stdout}\nstderr: #{stderr}"
    expect(stderr).to be_empty
  end

  it 'joins short body lines and wraps paragraphs at 72 characters' do
    result = run_script(input: "Cache parsed documents\n\n#{unformatted_body}")

    expect_success(result)
    expect(result.first).to eq("Cache parsed documents\n\n#{formatted_body}")
  end

  it 'preserves the first physical line and inserts the missing blank second line' do
    subject = '# **Preserve this long subject even when it exceeds fifty characters**  '
    result = run_script(input: "#{subject}\n#{unformatted_body}")

    expect_success(result)
    expect(result.first).to eq("#{subject}\n\n#{formatted_body}")
  end

  it 'keeps separate paragraphs, lists, and fenced code distinct' do
    message = <<~MESSAGE
      Document the cache

      First paragraph.

      - Use the
        cache.
      - Read the source.

      ```python
      print("This code line deliberately extends past the seventy-two-character wrapping target.")
      ```
    MESSAGE
    expected = <<~MESSAGE
      Document the cache

      First paragraph.

      - Use the cache.
      - Read the source.

      ```python
      print("This code line deliberately extends past the seventy-two-character wrapping target.")
      ```
    MESSAGE

    result = run_script(input: message)

    expect_success(result)
    expect(result.first).to eq(expected)
  end

  it 'preserves raw trailer spacing, duplicate keys, and folded values' do
    trailers = "Reviewed-by \t:  Alice <alice@example.com>  \n" \
      "Reviewed-by: Bob <bob@example.com>\n" \
      "Notes: Keep this value\n\tand this continuation exactly.  \n" \
      "Format: markdown\n"
    result = run_script(input: "Cache parsed documents\n\n#{unformatted_body}\n#{trailers}")

    expect_success(result)
    expect(result.first).to eq("Cache parsed documents\n\n#{formatted_body}\n#{trailers}")
  end

  it 'finds trailers after a Markdown horizontal rule' do
    message = "Cache parsed documents\n\n#{unformatted_body}\n---\n\n" \
      "Format: markdown\nAssisted-by: Codex\n"
    result = run_script(input: message)

    expect_success(result)
    expect(result.first).to eq(
      "Cache parsed documents\n\n#{formatted_body}\n______________________________________________________________________\n\n" \
        "Format: markdown\nAssisted-by: Codex\n"
    )
  end

  it 'does not split a fenced code block at a trailer-like line' do
    message = "Document trailers\n\n```text\nExample:\n\nSigned-off-by: Alice\n```\n"
    result = run_script(input: message)

    expect_success(result)
    expect(result.first).to eq(message)
  end

  it 'preserves Unicode line separators in the physical subject' do
    message = "Keep\u2028this subject\n\n#{unformatted_body}"
    result = run_script(input: message)

    expect_success(result)
    expect(result.first).to eq("Keep\u2028this subject\n\n#{formatted_body}")
  end

  it 'preserves a mixed trailer block and its trailing blank lines' do
    trailers = "Signed-off-by: Alice\nAn accompanying note\n\n \t\n"
    result = run_script(input: "Cache parsed documents\n\n#{unformatted_body}\n#{trailers}")

    expect_success(result)
    expect(result.first).to eq("Cache parsed documents\n\n#{formatted_body}\n#{trailers}")
  end

  it 'preserves trailers without a final newline' do
    trailers = 'Format: markdown'
    result = run_script(input: "Cache parsed documents\n\n#{unformatted_body}\n#{trailers}")

    expect_success(result)
    expect(result.first).to eq("Cache parsed documents\n\n#{formatted_body}\n#{trailers}")
  end

  it 'preserves trailers when there is no body' do
    message = "Fix cache lookup\n\nSigned-off-by: Alice <alice@example.com>\nFormat: markdown\n"
    result = run_script(input: message)

    expect_success(result)
    expect(result.first).to eq(message)
  end

  it 'does not mistake a colon inside an ordinary paragraph for trailers' do
    message = "Explain cache invalidation\n\nReason: the source changed\nso discard the cache.\n"
    result = run_script(input: message)

    expect_success(result)
    expect(result.first).to eq(
      "Explain cache invalidation\n\nReason: the source changed so discard the cache.\n"
    )
  end

  it 'leaves empty input empty' do
    result = run_script

    expect_success(result)
    expect(result.first).to be_empty
  end

  it 'adds a final newline to a subject-only message' do
    result = run_script(input: 'Fix cache lookup')

    expect_success(result)
    expect(result.first).to eq("Fix cache lookup\n")
  end

  it 'accepts an explicit stdin argument' do
    result = run_script('-', input: "Cache parsed documents\n\n#{unformatted_body}")

    expect_success(result)
    expect(result.first).to eq("Cache parsed documents\n\n#{formatted_body}")
  end

  it 'prints a formatted file without changing the input file' do
    original = "Cache parsed documents\n\n#{unformatted_body}"
    File.write(message_file, original)

    result = run_script(message_file)

    expect_success(result)
    expect(result.first).to eq("Cache parsed documents\n\n#{formatted_body}")
    expect(File.read(message_file)).to eq(original)
  end

  it 'formats a UTF-8 file in place without writing the result to stdout' do
    File.write(message_file, "修正快取\n\n#{unformatted_body}")

    result = run_script('--in-place', message_file)

    expect_success(result)
    expect(result.first).to be_empty
    expect(File.read(message_file)).to eq("修正快取\n\n#{formatted_body}")
  end

  it 'produces the same message when run again' do
    first = run_script(input: "Cache parsed documents\n\n#{unformatted_body}\nFormat: markdown\n")
    expect_success(first)

    second = run_script(input: first.first)

    expect_success(second)
    expect(second.first).to eq(first.first)
  end

  it 'rejects in-place formatting of stdin' do
    stdout, stderr, status = run_script('--in-place', '-')

    expect(status).not_to be_success
    expect(stdout).to be_empty
    expect(stderr).not_to be_empty
  end

  it 'reports missing input files without producing a message' do
    stdout, stderr, status = run_script(message_file)

    expect(status).not_to be_success
    expect(stdout).to be_empty
    expect(stderr).to include(message_file)
  end

  it 'leaves an invalid UTF-8 file unchanged when in-place formatting fails' do
    original = "Fix cache lookup\n\n\xFF".b
    File.binwrite(message_file, original)

    stdout, stderr, status = run_script('--in-place', message_file)

    expect(status).not_to be_success
    expect(stdout).to be_empty
    expect(stderr).not_to be_empty
    expect(File.binread(message_file)).to eq(original)
  end
end
