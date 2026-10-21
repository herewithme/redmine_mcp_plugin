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
        '"text":https://example.com; #123 links an issue. Markdown syntax (# headings, **bold**, ' \
        '"- " bullets, backticks, [text](url)) does not render.',
      'common_mark' =>
        'Text fields marked "Rendered as CommonMark Markdown" take GitHub-flavoured Markdown: # headings, ' \
        '**bold**, _italic_, "- " bullets and "1. " numbered lists, pipe tables with a |---| separator ' \
        'row, ``` fenced code, [text](url) links; #123 links an issue. Textile syntax does not render.'
    }.freeze

    PLAIN = 'Fields marked "Plain text" take no markup.'

    # Company style, not a Redmine rule: told to the agent, never applied by the server.
    DASHES = 'Write every dash as a plain hyphen-minus "-", never an en dash "–" or an em dash "—", ' \
             'in rendered and plain-text fields alike.'

    # The short form for parameter descriptions, paid on every request. A spaced
    # hyphen is safe under Textile and CommonMark; a blank setting renders nothing.
    DASH_RULE  = 'Dashes: plain "-"'
    DASH_NEVER = 'never "–"/"—".'
    SPACED_SAFE = %w[textile common_mark].freeze

    module_function

    def name
      NAMES.fetch(Setting.text_formatting.to_s, 'plain text')
    end

    def rendered_suffix
      safe = SPACED_SAFE.include?(Setting.text_formatting.to_s) ? ' (" - " is safe)' : ''
      "Rendered as #{name}. #{DASH_RULE}#{safe}, #{DASH_NEVER}"
    end

    def plain_suffix
      "Plain text. #{DASH_RULE}, #{DASH_NEVER}"
    end

    # fields_tool is the endpoint's own tool that reports custom fields, or nil.
    def guide(fields_tool = nil)
      format = GUIDES[Setting.text_formatting.to_s]
      text   = format ? "#{format} #{PLAIN} #{custom_fields_rule(fields_tool)}" : 'No text field renders markup; write plain text everywhere.'
      "#{text} #{DASHES}"
    end

    def custom_fields_rule(fields_tool)
      return 'Custom fields render only when their definition enables text formatting.' if fields_tool.nil?

      "Custom fields render only when #{fields_tool} reports them rendered."
    end
  end
end
