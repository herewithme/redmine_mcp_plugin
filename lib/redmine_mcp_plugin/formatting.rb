# frozen_string_literal: true

module RedmineMcpPlugin
  # What Redmine renders in its text fields, read from the setting at call time
  # so the schema and the instructions follow the instance rather than a guess.
  module Formatting
    NAMES = { 'textile' => 'Textile', 'common_mark' => 'CommonMark Markdown' }.freeze

    GUIDES = {
      'textile' =>
        'Text fields marked "Rendered as Textile" take Textile, not Markdown: "h2. Title" on its own ' \
        'line for a heading; *bold*, _italic_; lines starting "* " for bullets and "# " for numbered ' \
        'lists; tables one row per line, "|_. Header |_. Header |" then "| cell | cell |"; @inline ' \
        'code@, or a block between <pre><code class="ruby"> and </code></pre>; links ' \
        '"text":https://example.com; #123 links an issue. Markdown syntax (#, **, -, backticks, ' \
        '[text](url)) does not render.',
      'common_mark' =>
        'Text fields marked "Rendered as CommonMark Markdown" take GitHub-flavoured Markdown: # headings, ' \
        '**bold**, _italic_, "- " bullets and "1. " numbered lists, pipe tables with a |---| separator ' \
        'row, ``` fenced code, [text](url) links; #123 links an issue. Textile syntax does not render.'
    }.freeze

    PLAIN = 'Fields marked "Plain text" take no markup. Custom fields render only when ' \
            'get_issue_fields reports them rendered.'

    module_function

    def name
      NAMES.fetch(Setting.text_formatting.to_s, 'plain text')
    end

    def guide
      format = GUIDES[Setting.text_formatting.to_s]
      format ? "#{format} #{PLAIN}" : 'No text field renders markup; write plain text everywhere.'
    end
  end
end
