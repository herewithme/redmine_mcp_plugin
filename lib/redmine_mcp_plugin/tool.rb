# frozen_string_literal: true

module RedmineMcpPlugin
  # Base class for every exposed tool.
  #
  # The permission model here is belt and braces, and the second belt is not
  # redundant:
  #
  #   1. `permission` is checked through User#allowed_to?, which intersects the
  #      user's role permissions with the OAuth token's scopes.
  #   2. Each tool additionally reads through core's .visible scopes.
  #
  # Both are required. Core's SQL visibility scopes go through
  # Project.allowed_to_condition, which calls role.allowed_to?(permission) with
  # NO scope argument -- so .visible honours roles but is blind to OAuth scopes.
  # Relying on .visible alone would let a token scoped to view_wiki_pages read
  # issues. Relying on allowed_to? alone would return rows from projects the
  # user is not a member of. Neither check subsumes the other.
  class Tool
    class << self
      attr_reader :mcp_name, :mcp_title, :mcp_description, :mcp_schema,
                  :mcp_permission, :mcp_write, :mcp_destructive

      # `scopes` are permissions the tool checks beyond the one that gates it;
      # they are advertised so a token can carry them, and gate nothing.
      # `rendered` names the parameters Redmine passes through its text formatter,
      # `plain` the ones it prints as they are; both get the dash rule when listed.
      # `plugin` ties the whole tool to an installed plugin, `plugin_properties`
      # and `plugin_scopes` tie single parameters and scopes to one.
      def tool(name, title:, description:, schema:, permission: nil, scopes: [], rendered: [], plain: [],
               write: false, destructive: false, plugin: nil, plugin_properties: {}, plugin_scopes: {})
        @mcp_name          = name.to_s
        @mcp_title         = title
        @mcp_description   = description
        @mcp_schema        = schema
        @mcp_permission    = permission
        @mcp_scopes        = scopes
        @mcp_rendered      = rendered
        @mcp_plain         = plain
        @mcp_write         = write
        @mcp_destructive   = destructive
        @mcp_plugin        = plugin
        @plugin_properties = plugin_properties
        @plugin_scopes     = plugin_scopes
      end

      def write?       = !!@mcp_write
      def destructive? = !!@mcp_destructive
      def mcp_rendered = Array(@mcp_rendered)
      def mcp_plain    = Array(@mcp_plain)

      # Read per call, never at class load: this plugin boots before some of
      # the plugins it looks for.
      def plugin?(id) = Redmine::Plugin.installed?(id)

      def installed? = @mcp_plugin.nil? || plugin?(@mcp_plugin)

      def mcp_scopes
        Array(@mcp_scopes) + @plugin_scopes.to_h.select { |id, _scopes| plugin?(id) }.values.flatten
      end

      # Core grants some abilities through more than one permission, so any of
      # them admits the tool; the tool applies core's real rule per record.
      def mcp_permissions = Array(@mcp_permission)

      # Whether this tool should appear in tools/list for the current user.
      # tools/list is allowed to vary by the authorization presented on the
      # request -- the 2026-07-28 spec says so explicitly -- and hiding a tool
      # the caller could never successfully call is friendlier than letting a
      # model discover it and fail.
      def available_to?(user)
        return false unless installed?
        return false if write? && Settings.read_only?
        return true  if mcp_permissions.empty?

        mcp_permissions.any? { |permission| user.allowed_to?(permission, nil, global: true) }
      end

      def descriptor
        {
          name: mcp_name,
          title: mcp_title,
          description: mcp_description,
          inputSchema: schema_with_format,
          # Clients read these to decide whether a call needs confirming by the
          # user. Omitting them makes a read-only server look exactly like a
          # destructive one, so every lookup gets a prompt.
          annotations: {
            readOnlyHint: !write?,
            destructiveHint: destructive?,
            idempotentHint: !write?
          }
        }
      end

      # The schema minus the parameters of plugins that are not installed. The
      # served list and validation both use it, so an absent plugin leaves nothing.
      def effective_schema
        absent = @plugin_properties.to_h.reject { |id, _names| plugin?(id) }.values.flatten
        return mcp_schema if absent.empty?

        mcp_schema.merge('properties' => mcp_schema['properties'].except(*absent))
      end

      # The format is a setting, so the suffix is added when the list is served,
      # not when the class loads. Validation keeps using the bare schema.
      def schema_with_format
        schema = effective_schema
        return schema if mcp_rendered.empty? && mcp_plain.empty?

        properties = schema['properties'].to_h do |name, spec|
          suffix = Formatting.rendered_suffix if mcp_rendered.include?(name)
          suffix = Formatting.plain_suffix    if mcp_plain.include?(name)
          next [name, spec] unless suffix

          [name, spec.merge('description' => "#{spec['description']} #{suffix}".strip)]
        end
        schema.merge('properties' => properties)
      end
    end

    # `auth` carries what core does not expose. Redmine declares
    # `attr_writer :oauth_scope` on User with no matching reader, so the granted
    # scopes cannot be read back off the model once set -- the plugin has to
    # remember them itself.
    def initialize(user, auth = {})
      @user = user
      @auth = auth || {}
    end

    attr_reader :user, :auth

    def auth_mode   = @auth[:mode]
    def oauth?      = @auth[:mode] == :oauth2
    def oauth_scopes = @auth[:scopes]

    # Invoked by the dispatcher. Subclasses implement #perform.
    def call(arguments)
      klass = self.class
      raise PermissionError, 'This tool is disabled: the server is in read-only mode' if klass.write? && Settings.read_only?

      permissions = klass.mcp_permissions
      if permissions.any? && permissions.none? { |p| user.allowed_to?(p, nil, global: true) }
        raise PermissionError, 'You do not have permission to use this tool'
      end

      arguments ||= {}
      # The schemas are a contract with the caller, not a comment. Checked here
      # rather than in each tool so a tool cannot forget.
      schema = klass.effective_schema
      SchemaValidator.validate!(schema, arguments)
      # And normalised, so a tool never has to decide what the string "false"
      # means. It means false.
      arguments = SchemaValidator.coerce(schema, arguments)

      perform(arguments)
    end

    private

    def perform(_arguments)
      raise NotImplementedError
    end

    def plugin?(id) = self.class.plugin?(id)

    # --- helpers available to every tool ----------------------------------

    # Confirms the user may do `permission` in `project`, honouring OAuth
    # scopes. Use this for anything scoped to one project; the .visible scopes
    # alone will not catch a scope-narrowed token.
    # ToolError, not PermissionError: this one is scoped to a single project, so
    # the caller can act on it by asking about a different project. Tool-level
    # refusals in #call stay protocol errors. The wording is unchanged and stays
    # uniform -- a message that varies by cause is an information leak.
    def authorize!(permission, project)
      raise ToolError, 'You do not have permission to do that' unless user.allowed_to?(permission, project)
    end

    # add_issue_notes is granted per tracker: authorize! covers the project and
    # the scope, notes_addable? the tracker, and init_journal skips core's own check.
    def authorize_note!(issue)
      authorize!(:add_issue_notes, issue.project)
      raise ToolError, 'You do not have permission to do that' unless issue.notes_addable?(user)
    end

    # Core allows edit_issues, or edit_own_issues on one's own issue, per
    # tracker. attributes_editable? misses OAuth scopes; allowed_to? misses trackers.
    def authorize_edit!(issue)
      scoped = user.allowed_to?(:edit_issues, issue.project) ||
               (issue.author_id == user.id && user.allowed_to?(:edit_own_issues, issue.project))
      raise ToolError, 'You do not have permission to do that' unless scoped && issue.attributes_editable?(user)
    end

    # SchemaValidator has already refused a non-integer or below-minimum limit,
    # so all that is left is the server-side cap. max_results is the
    # administrator's ceiling, not a suggestion the caller may raise.
    def limit_for(arguments)
      requested = arguments['limit'].presence&.to_i
      return Settings.max_results if requested.nil?

      # Clamped to 1, not just capped. SchemaValidator rejects a limit below
      # the declared minimum, but only for a tool that declares one. A new list
      # tool that omits it would otherwise pass a negative straight to
      # ActiveRecord, which raises. max_results stays the administrator's
      # ceiling.
      [[requested, 1].max, Settings.max_results].min
    end

    def offset_for(arguments)
      # Clamped for the same reason as limit_for.
      [arguments['offset'].presence&.to_i || 0, 0].max
    end

    # One envelope for every list tool, so a caller pages all of them the same
    # way. Without an offset the cap on limit made everything past the first
    # max_results rows unreachable: on the instance this was tested against,
    # 585 of 685 projects and all but 100 issues.
    def paged(total:, offset:, key:, rows:)
      {
        total_count: total,
        returned: rows.size,
        offset: offset,
        has_more: offset + rows.size < total,
        key => rows
      }
    end

    def fetch_project(identifier)
      raise ToolError, 'project is required' if identifier.blank?

      project = Project.visible(user).find_by(identifier: identifier.to_s) ||
                Project.visible(user).find_by(id: identifier.to_s.to_i)
      # Deliberately the same message whether the project does not exist or is
      # merely invisible: distinguishing them confirms the existence of projects
      # the caller cannot see.
      raise ToolError, "No visible project matching #{identifier.inspect}" if project.nil?

      project
    end

    # Visibility only, like fetch_project; the caller adds authorize! for its permission.
    def fetch_issue(id)
      issue = Issue.visible(user).find_by(id: id.to_i)
      raise ToolError, "No visible issue with id #{id.inspect}" if issue.nil?

      issue
    end

    def fetch_news(id)
      news = News.visible(user).find_by(id: id.to_i)
      raise ToolError, "No visible news with id #{id.inspect}" if news.nil?

      news
    end

    # allowed_to? is false for a disabled module, which would read as a
    # permissions problem; name the real cause instead.
    def require_module!(project, name)
      return if project.module_enabled?(name)

      raise ToolError, "The #{name} module is not enabled for project #{project.identifier}"
    end

    # Both wiki tools need these three checks, in this order.
    #
    # The module check comes first because allowed_to? returns false for a
    # disabled module, so a project whose wiki is merely switched off otherwise
    # reports "You do not have permission" -- which sent one reviewer looking
    # for a permissions bug that was not there. Naming the real cause leaks
    # nothing: get_project already returns enabled_modules to anyone who can
    # see the project.
    def fetch_wiki(project)
      require_module!(project, :wiki)
      authorize!(:view_wiki_pages, project)

      wiki = project.wiki
      raise ToolError, "Project #{project.identifier} has no wiki" if wiki.nil? || !wiki.visible?(user)

      wiki
    end

    # People are named by id or "me" everywhere. Query filters pass "me" on to
    # core, which also adds the user's groups; writes resolve it here.
    def user_ref!(value, name)
      return value if value == 'me' || SchemaValidator.integerish?(value)

      raise ToolError, "#{name} must be a user id from list_users, or \"me\""
    end

    def user_id_from(value, name)
      user_ref!(value, name) == 'me' ? user.id : value.to_i
    end

    def iso(time)
      time&.iso8601
    end

    def iso_date(value, name)
      Date.iso8601(value.to_s).iso8601
    rescue ArgumentError
      raise ToolError, "#{name} must be an ISO-8601 date, got #{value.inspect}"
    end

    # Built the way Redmine builds links in its notification emails, not from
    # the request. nil when unset: a missing setting must not fail a done write.
    def absolute_url(helper, *args, **options)
      return nil if Setting.host_name.blank?

      Rails.application.routes.url_helpers.public_send(helper, *args, **options, **Mailer.default_url_options)
    end

    # --- issue writes -------------------------------------------------------

    # parameter => [core attribute, kind]. The plain kinds (text, date, integer,
    # number, boolean) need no resolver, so a new such field is one row here and
    # one schema line. tracker and parent keep their raw value and are resolved
    # after refuse_unsettable!, so the permission refusal comes first.
    WRITE_ATTRIBUTES = {
      'subject'             => %w[subject text],
      'description'         => %w[description text],
      'tracker'             => %w[tracker_id tracker],
      'status'              => %w[status_id status],
      'priority'            => %w[priority_id priority],
      'category'            => %w[category_id category],
      'fixed_version'       => %w[fixed_version_id fixed_version],
      'assigned_to'         => %w[assigned_to_id assigned_to],
      'parent'              => %w[parent_issue_id parent],
      'start_date'          => %w[start_date date],
      'due_date'            => %w[due_date date],
      'done_ratio'          => %w[done_ratio integer],
      'estimated_hours'     => %w[estimated_hours number],
      'is_private'          => %w[is_private boolean],
      'watcher_users'       => %w[watcher_user_ids watcher_users],
      'custom_field_values' => %w[custom_field_values custom_field_values]
    }.freeze
    PARAMETER_NAMES = WRITE_ATTRIBUTES.to_h { |name, (attribute, _kind)| [attribute, name] }
                                      .merge('checklists_attributes' => 'checklists').freeze
    # "none" clears these; parent handles it on its own path.
    CLEARABLE = %w[date category fixed_version assigned_to].freeze
    TAG_KEYS  = %w[tag_list add_tag_list remove_tag_list].freeze

    def issue_attributes_from(issue, arguments)
      WRITE_ATTRIBUTES.each_with_object({}) do |(name, (attribute, kind)), attributes|
        value = arguments[name]
        next if value.nil?

        clear  = value == 'none' && CLEARABLE.include?(kind)
        result = clear ? '' : issue_value(issue, name, kind, value)
        attributes[attribute] = result unless result.nil?
      end
    end

    def issue_value(issue, name, kind, value)
      case kind
      when 'text'                then value.to_s
      when 'date'                then iso_date(value, name)
      when 'status'              then status_id(value)
      when 'priority'            then priority_id(value)
      when 'category'            then issue_category_id(issue, value)
      when 'fixed_version'       then issue_version_id(issue, value)
      when 'assigned_to'         then assignee_id(issue, value)
      when 'watcher_users'       then watcher_ids(issue, value, name)
      when 'custom_field_values' then custom_field_values_from(value)
      else value
      end
    end

    # Core drops what the role, tracker or workflow forbids and saves the rest;
    # name it and stop instead.
    def refuse_unsettable!(record, attributes)
      unsafe = attributes.keys.reject { |key| record.safe_attribute?(key, user) }
      return if unsafe.empty?

      names = unsafe.map { |key| PARAMETER_NAMES.fetch(key, key) }.join(', ')
      raise ToolError, "Cannot set #{names} on this #{record.class.model_name.human.downcase}"
    end

    # add_issues is granted per tracker, and core would silently substitute a
    # permitted one -- which an agent reports as success. Refuse instead. Core
    # applies the same rule when an existing issue changes tracker.
    def tracker_for(issue, name)
      allowed = issue.allowed_target_trackers(user)
      project = issue.project
      if name.blank?
        trackers = allowed.to_a
        raise ToolError, 'You do not have permission to do that' if trackers.empty?
        return trackers.first if trackers.one?

        raise ToolError, "Pass tracker. #{project.identifier} allows: #{trackers.map(&:name).join(', ')}"
      end

      tracker = project.trackers.find_by(name: name.to_s)
      raise ToolError, "Project #{project.identifier} has no tracker named #{name.inspect}" if tracker.nil?
      unless allowed.where(id: tracker.id).exists?
        # One core rule, two acts: creating with a tracker, or moving an issue to one.
        act = issue.new_record? ? 'create issues with' : 'move issues to'
        raise ToolError, "You do not have permission to #{act} tracker #{name.inspect} in project #{project.identifier}"
      end

      tracker
    end

    def status_id(name)
      status = IssueStatus.find_by(name: name.to_s)
      raise ToolError, "No issue status named #{name.inspect}" if status.nil?

      status.id
    end

    # Core keeps the old status silently when the workflow has no such transition.
    def refuse_status!(issue, status_id, name)
      return if status_id == issue.status_id

      allowed = issue.new_statuses_allowed_to(user)
      return if allowed.any? { |status| status.id == status_id }

      names = allowed.map(&:name)
      raise ToolError, "Status #{name.inspect} is not allowed here. Allowed: #{names.any? ? names.join(', ') : 'none'}"
    end

    def priority_id(name)
      priority = IssuePriority.active.find_by(name: name.to_s)
      raise ToolError, "No active priority named #{name.inspect}" if priority.nil?

      priority.id
    end

    # Name or id against the project's own list; names are unique per project.
    def issue_category_id(issue, value)
      categories = issue.project.issue_categories.to_a
      category   = categories.detect { |c| c.id.to_s == value.to_s || c.name == value.to_s }
      return category.id if category

      raise ToolError, "No category #{value.inspect} in #{issue.project.identifier}. " \
                       "Categories: #{categories.map(&:name).join(', ')}"
    end

    # Core's own list for this issue; shared versions of other projects may repeat a name.
    def issue_version_id(issue, value)
      versions = issue.assignable_versions
      found    = versions.select { |v| v.id.to_s == value.to_s || v.name == value.to_s }
      return found.first.id if found.one?

      choices = (found.any? ? found : versions).map { |v| "#{v.name} (#{v.project.identifier}) id #{v.id}" }.join(', ')
      raise ToolError, "Version #{value.inspect} is ambiguous here; pass the id: #{choices}" if found.any?

      raise ToolError, "No assignable version #{value.inspect} for #{issue.project.identifier}. Versions: #{choices}"
    end

    # Core computes % done from the status under this setting and hides the field.
    def refuse_done_ratio!(attributes)
      return unless attributes.key?('done_ratio') && !Issue.use_field_for_done_ratio?

      raise ToolError, 'Cannot set done_ratio: this Redmine computes % done from the status'
    end

    # Core's own rule, which also admits the author and the current assignee.
    def assignee_id(issue, value)
      id = user_id_from(value, 'assigned_to')
      return id if issue.assignable_users.any? { |principal| principal.id == id }

      raise ToolError, "#{id} is not assignable on #{issue.project.identifier}"
    end

    # Core says only "Parent task is invalid" for several causes; name them with
    # its own predicates. Runs after refuse_unsettable!, so permission comes first.
    def parent_attribute(issue, value)
      return '' if value == 'none'
      raise ToolError, 'parent must be an issue id, or "none"' unless SchemaValidator.integerish?(value)

      parent = fetch_issue(value)
      if !issue.new_record? && issue.is_or_is_ancestor_of?(parent)
        raise ToolError, "Parent ##{parent.id} is this issue or one of its subtasks"
      end
      unless issue.valid_parent_project?(parent)
        raise ToolError, "Parent ##{parent.id} is in #{parent.project.identifier}, outside what the " \
                         "cross-project subtasks setting (#{cross_project_label}) allows"
      end

      parent.id.to_s
    end

    def cross_project_label
      setting = Setting.cross_project_subtasks
      setting.present? ? I18n.t("label_cross_project_#{setting}") : I18n.t(:label_disabled)
    end

    # Same reason: core keeps only the custom fields this user may edit here.
    def refuse_unknown_custom_fields!(record, ids)
      editable = record.editable_custom_field_values(user).map { |value| value.custom_field_id.to_s }
      unknown  = Array(ids).map(&:to_s) - editable
      return if unknown.empty?

      names = CustomField.where(id: unknown).pluck(:id, :name).to_h
      list  = unknown.map { |id| names[id.to_i] || "id #{id}" }.join(', ')
      raise ToolError, "Custom fields #{list} cannot be set on this #{record.class.model_name.human.downcase}"
    end

    # --- watchers -----------------------------------------------------------

    # Core's own list: the project's principals who may watch, minus current
    # watchers and anyone who cannot see the issue.
    def watcher_ids(issue, values, name)
      Array(values).map do |value|
        id = user_id_from(value, name)
        next id if issue.addable_watcher_users.any? { |principal| principal.id == id }

        raise ToolError, "User #{id} cannot be added as a watcher of this issue"
      end
    end

    # Oneself follows core's Watch link, which needs no permission; anyone else
    # needs add_issue_watchers or delete_issue_watchers, as core's own actions do.
    def watcher_changes(issue, arguments)
      adds = Array(arguments['add_watcher_users']).map { |v| user_id_from(v, 'add_watcher_users') }.uniq
      removes = Array(arguments['remove_watcher_users']).map { |v| user_id_from(v, 'remove_watcher_users') }.uniq
      authorize!(:add_issue_watchers, issue.project)    if adds.any? { |id| id != user.id }
      authorize!(:delete_issue_watchers, issue.project) if removes.any? { |id| id != user.id }

      principals_to_add = adds.map do |id|
        next user if id == user.id

        issue.addable_watcher_users.detect { |p| p.id == id } ||
          raise(ToolError, "User #{id} cannot be added as a watcher of ##{issue.id}")
      end
      principals_to_remove = removes.map do |id|
        issue.watcher_users.detect { |p| p.id == id } || raise(ToolError, "User #{id} is not a watcher of ##{issue.id}")
      end
      [principals_to_add, principals_to_remove]
    end

    def apply_watcher_changes!(issue, adds, removes)
      adds.each    { |principal| issue.add_watcher(principal) unless issue.watched_by?(principal) }
      removes.each { |principal| issue.remove_watcher(principal) }
    end

    def principal_row(principal)
      { id: principal.id, name: principal.name, type: principal.class.name }
    end

    # --- attachments --------------------------------------------------------

    def attachment_row(attachment)
      {
        id: attachment.id,
        filename: attachment.filename,
        filesize: attachment.filesize,
        content_type: attachment.content_type,
        author: attachment.author&.name,
        description: attachment.description,
        created_on: iso(attachment.created_on),
        url: absolute_url(:download_named_attachment_url, attachment, attachment.filename)
      }
    end

    # --- plugins: redmineup_tags and redmine_checklists -----------------------

    # The plugin applies tags silently only with edit_tags, and drops tags that
    # do not exist yet without create_tags; both are refused here by name.
    def tag_attributes(issue, arguments)
      sent = TAG_KEYS.select { |key| !arguments[key].nil? }
      return {} if sent.empty?

      authorize!(:edit_tags, issue.project)
      lists = sent.to_h { |key| [key, Array(arguments[key]).map(&:to_s).reject(&:blank?)] }
      added = (lists['tag_list'] || []) + (lists['add_tag_list'] || [])
      unless added.empty? || user.allowed_to?(:create_tags, issue.project)
        unknown = added - Issue.all_tags.map(&:name)
        raise ToolError, "Tags not yet existing need the Create tags permission: #{unknown.join(', ')}" if unknown.any?
      end
      lists
    end

    # The plugin's listener writes the journal detail. Called on its own with the
    # two keys it reads: the issue, and the list it checks for presence.
    def journal_tags!(issue)
      RedmineupTags::Hooks::ModelIssueHook.instance.controller_issues_edit_before_save(
        issue: issue, params: { issue: { tag_list: issue.tag_list.to_a } }
      )
    end

    # The plugin's listener journals the change and recalculates the done ratio;
    # it reads the issue and the journal, nothing else.
    def journal_checklists!(issue)
      RedmineChecklists::Hooks::ControllerIssuesHook.instance.controller_issues_edit_after_save(
        issue: issue, journal: issue.current_journal
      )
    end

    def checklist_row(item)
      { id: item.id, subject: item.subject, is_done: item.is_done, is_section: item.is_section, position: item.position }
    end

    # --- saved state --------------------------------------------------------

    STATE_READERS = {
      'description'     => ->(issue) { issue.description },
      'category'        => ->(issue) { issue.category&.name },
      'fixed_version'   => ->(issue) { issue.fixed_version&.name },
      'start_date'      => ->(issue) { issue.start_date&.iso8601 },
      'due_date'        => ->(issue) { issue.due_date&.iso8601 },
      'done_ratio'      => ->(issue) { issue.done_ratio },
      'estimated_hours' => ->(issue) { issue.estimated_hours&.to_f },
      'is_private'      => ->(issue) { issue.is_private? },
      'watcher_users'   => ->(issue) { issue.watcher_users.map(&:name) },
      'tag_list'        => ->(issue) { issue.tag_list.to_a },
      'checklists'      => ->(issue) { issue.checklists.map { |item| { id: item.id, subject: item.subject, is_done: item.is_done } } }
    }.freeze
    STATE_ALIASES = { 'add_watcher_users' => 'watcher_users', 'remove_watcher_users' => 'watcher_users',
                      'add_tag_list' => 'tag_list', 'remove_tag_list' => 'tag_list' }.freeze

    # The issue as saved, read back off the record: the base set, plus every
    # field the caller sent, plus the custom fields they sent.
    def issue_state(issue, arguments)
      state = {
        id: issue.id,
        subject: issue.subject,
        project_identifier: issue.project&.identifier,
        tracker: issue.tracker&.name,
        status: issue.status&.name,
        assigned_to: issue.assigned_to&.name,
        priority: issue.priority&.name,
        parent: issue.parent_id
      }
      sent = arguments.keys.map { |key| STATE_ALIASES.fetch(key, key) }
      STATE_READERS.each { |name, read| state[name.to_sym] = read.call(issue) if sent.include?(name) }
      state[:custom_fields] = saved_custom_fields(issue, custom_field_ids(arguments))
      state[:url] = absolute_url(:issue_url, issue)
      state
    end

    # --- news ---------------------------------------------------------------

    def news_attributes(arguments)
      %w[title summary description].each_with_object({}) do |field, attributes|
        attributes[field] = arguments[field].to_s unless arguments[field].nil?
      end
    end

    def news_state(news)
      {
        id: news.id,
        title: news.title,
        summary: news.summary,
        author: news.author&.name,
        created_on: iso(news.created_on),
        project_identifier: news.project&.identifier,
        comments_count: news.comments_count,
        url: absolute_url(:news_url, news)
      }
    end

    def saved_custom_fields(record, ids)
      Array(ids).filter_map do |id|
        value = record.custom_field_values.detect { |v| v.custom_field_id.to_s == id.to_s }
        next if value.nil?

        { id: value.custom_field_id, name: value.custom_field.name, value: value.value }
      end
    end

    # SchemaValidator does not walk into an object, so the shape is checked here.
    def custom_field_values_from(raw)
      return nil if raw.blank?
      raise ToolError, 'custom_field_values must be an object keyed by numeric custom field id' unless raw.is_a?(Hash)

      raw.each_with_object({}) do |(id, value), out|
        raise ToolError, "custom_field_values key #{id.inspect} is not a numeric custom field id" unless /\A\d+\z/.match?(id.to_s)
        raise ToolError, "custom_field_values[#{id}] must be a string, a number, or an array of them" if value.is_a?(Hash)

        out[id.to_s] = value.is_a?(Array) ? value.map(&:to_s) : value.to_s
      end
    end

    def custom_field_ids(arguments)
      arguments['custom_field_values'].is_a?(Hash) ? arguments['custom_field_values'].keys : []
    end
  end
end
