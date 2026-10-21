# frozen_string_literal: true

module RedmineMcpPlugin
  # One MCP server: its URL, identity, instructions and tools. /mcp is the main one; another plugin
  # mounts more under /mcp/<path> with Endpoint.register, sharing this plugin's settings, auth and refusals.
  class Endpoint
    PATH = /\A[a-z0-9][a-z0-9_-]*\z/
    # What the shared messages point to: users, project ids, custom fields that render.
    HINTS = %i[users projects fields].freeze

    INSTRUCTIONS = 'Redmine over MCP. Every tool runs as the authenticated Redmine user and is ' \
                   'limited by that user\'s project permissions, and by the OAuth2 scopes of the ' \
                   'presented token where one is used. Results are already filtered; an empty ' \
                   'result means nothing visible matched, not that nothing exists. After a write, ' \
                   'report the saved state from the reply, not what was requested, and ask the ' \
                   'user to check the returned url.'

    attr_reader :path, :name, :title, :version, :instructions, :resource_name, :documentation, :hints

    def initialize(path:, name:, title:, instructions:, tools:, version: VERSION, resource_name: title,
                   documentation: nil, hints: {})
      @path          = path
      @name          = name
      @title         = title
      @version       = version
      @instructions  = instructions
      @tools         = tools
      @resource_name = resource_name
      @documentation = documentation
      @hints         = hints
    end

    # The main list is read per call, as Registry has always been; an extension's is fixed when it registers.
    def tools = @tools.respond_to?(:call) ? @tools.call : @tools

    def mount_path = path ? "/mcp/#{path}" : '/mcp'

    def server_info
      { name: name, title: title, version: version }
    end

    # Tools this user may see. tools/list is permitted to vary by the
    # authorization on the request; the 2026-07-28 spec says so explicitly,
    # and it means a scope-narrowed token is not shown tools it cannot call.
    def visible_to(user)
      tools.select { |tool| tool.available_to?(user) }
    end

    def find(name, user)
      visible_to(user).detect { |tool| tool.mcp_name == name.to_s }
    end

    class << self
      def main
        @main ||= new(path: nil, name: 'redmine-mcp-plugin', title: 'Redmine', instructions: INSTRUCTIONS,
                      tools: -> { Registry.all }, resource_name: 'Redmine MCP Server',
                      documentation: 'https://github.com/stenikgroup/redmine_mcp_plugin',
                      hints: { users: 'list_users', projects: 'list_projects', fields: 'get_issue_fields' })
      end

      # Called from another plugin's init.rb, which Redmine runs again after a code reload: the same
      # name may register its path again, a different name may not take it. A refused registration is
      # logged and not served, so an extension never stops Redmine booting.
      def register(path, name:, title:, instructions:, tools:, version: VERSION, hints: {})
        path = path.to_s
        raise ArgumentError, "MCP endpoint path #{path.inspect} must be one lowercase URL segment" unless PATH.match?(path)
        if [name, title, instructions].any?(&:blank?)
          raise ArgumentError, "MCP endpoint #{path} needs a name, a title and instructions"
        end

        existing = registered[path]
        if existing && existing.name != name
          raise ArgumentError, "MCP endpoint #{path} is already registered by #{existing.name}"
        end

        tools = checked_tools(path, tools)
        registered[path] = new(path: path, name: name, title: title, instructions: instructions,
                               tools: tools, version: version, hints: checked_hints(path, hints, tools))
      rescue ArgumentError => e
        Rails.logger.error("[redmine_mcp_plugin] #{name.presence || 'an endpoint'} is not served at /mcp/#{path}: #{e.message}")
        nil
      end

      # nil is the main endpoint; a path nobody registered is nil.
      def find(path) = path.nil? ? main : registered[path.to_s]

      def extension?(path) = registered.key?(path.to_s)

      private

      def registered = (@registered ||= {})

      def checked_tools(path, tools)
        valid = tools.is_a?(Array) && tools.any? &&
                tools.all? { |tool| tool.is_a?(Class) && tool < Tool && tool.mcp_name.present? }
        raise ArgumentError, "MCP endpoint #{path} needs a list of RedmineMcpPlugin::Tool subclasses" unless valid

        duplicates = tools.map(&:mcp_name).tally.select { |_name, count| count > 1 }.keys
        raise ArgumentError, "MCP endpoint #{path} lists tool #{duplicates.join(', ')} twice" if duplicates.any?

        tools.dup.freeze
      end

      # Each kind names one of the endpoint's own tools; a kind left out is pointed at none.
      def checked_hints(path, hints, tools)
        raise ArgumentError, "MCP endpoint #{path} needs hints as a Hash" unless hints.is_a?(Hash)

        hints   = hints.to_h { |kind, tool| [kind.to_s.to_sym, tool.to_s] }
        unknown = hints.keys - HINTS
        if unknown.any?
          raise ArgumentError, "MCP endpoint #{path} has unknown hints #{unknown.join(', ')}; known: #{HINTS.join(', ')}"
        end

        hints.each do |kind, tool|
          next if tools.any? { |t| t.mcp_name == tool }

          raise ArgumentError, "MCP endpoint #{path} hint #{kind} names #{tool}, which it does not list"
        end
        hints.freeze
      end
    end
  end
end
