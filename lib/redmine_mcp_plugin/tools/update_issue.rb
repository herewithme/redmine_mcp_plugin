# frozen_string_literal: true

module RedmineMcpPlugin
  module Tools
    class UpdateIssue < Tool
      tool 'update_issue',
           title: 'Update issue',
           description: 'Change an issue: any field get_issue_fields lists, custom fields, watchers, tags, ' \
                        'with an optional note in the same journal. Refused by name when the role or ' \
                        'workflow forbids. "none" clears an optional date or reference. End with the url.',
           permission: %i[edit_issues edit_own_issues],
           scopes: %i[manage_subtasks add_issue_watchers delete_issue_watchers set_issues_private set_own_issues_private],
           plugin_scopes: { redmineup_tags: %i[edit_tags create_tags] },
           plugin_properties: { redmineup_tags: %w[add_tag_list remove_tag_list] },
           rendered: %w[description notes],
           plain: %w[subject],
           write: true,
           destructive: true,
           schema: {
             'type' => 'object',
             'properties' => {
               'issue' => { 'type' => 'integer', 'description' => 'Issue id.' },
               'subject' => { 'type' => 'string' },
               'description' => { 'type' => 'string' },
               'tracker' => { 'type' => 'string', 'description' => 'Tracker name.' },
               'status' => { 'type' => 'string', 'description' => 'Status name.' },
               'priority' => { 'type' => 'string', 'description' => 'Priority name.' },
               'category' => { 'type' => %w[string integer], 'description' => 'Name or id.' },
               'fixed_version' => { 'type' => %w[string integer], 'description' => 'Target version, name or id.' },
               'assigned_to' => { 'type' => %w[integer string], 'description' => 'User id, or "me".' },
               'parent' => { 'type' => %w[integer string], 'description' => 'Parent issue id.' },
               'start_date' => { 'type' => 'string', 'description' => 'YYYY-MM-DD' },
               'due_date' => { 'type' => 'string', 'description' => 'YYYY-MM-DD' },
               'done_ratio' => { 'type' => 'integer' },
               'estimated_hours' => { 'type' => 'number' },
               'is_private' => { 'type' => 'boolean' },
               'add_watcher_users' => { 'type' => 'array', 'description' => 'User or group ids, or "me".' },
               'remove_watcher_users' => { 'type' => 'array', 'description' => 'User or group ids, or "me".' },
               'add_tag_list' => { 'type' => 'array', 'description' => 'Tag names.' },
               'remove_tag_list' => { 'type' => 'array', 'description' => 'Tag names.' },
               'custom_field_values' => { 'type' => 'object',
                                          'description' => 'By numeric field id, e.g. {"7": "3"}; the value, never the label.' },
               'notes' => { 'type' => 'string', 'description' => 'Note recorded with this change.' }
             },
             'required' => %w[issue],
             'additionalProperties' => false
           }

      private

      def perform(arguments)
        issue      = fetch_issue(arguments['issue'])
        attributes = issue_attributes_from(issue, arguments)
        tags       = plugin?(:redmineup_tags) ? tag_attributes(issue, arguments) : {}
        notes      = arguments['notes'].to_s
        watching   = %w[add_watcher_users remove_watcher_users].any? { |key| arguments[key].present? }
        if attributes.empty? && tags.empty? && notes.strip.empty? && !watching
          raise ToolError, 'Pass at least one field to change, or a note'
        end

        authorize_edit!(issue) if attributes.any?
        authorize_note!(issue) unless notes.strip.empty?
        refuse_unsettable!(issue, attributes)
        if attributes.key?('tracker_id')
          # Assigned now, so the status and custom field checks see the new tracker.
          issue.tracker = tracker_for(issue, arguments['tracker'])
          attributes['tracker_id'] = issue.tracker_id
        end
        refuse_status!(issue, attributes['status_id'], arguments['status']) if attributes.key?('status_id')
        refuse_done_ratio!(attributes)
        refuse_unknown_custom_fields!(issue, custom_field_ids(arguments))
        attributes['parent_issue_id'] = parent_attribute(issue, arguments['parent']) if attributes.key?('parent_issue_id')
        adds, removes = watcher_changes(issue, arguments)

        # notes delegates to the journal and is swallowed when there is none,
        # so the journal has to exist first.
        issue.init_journal(user, notes)
        # Indifferent access: the tags plugin reads its keys as symbols.
        issue.safe_attributes = attributes.merge(tags).with_indifferent_access
        journal_tags!(issue) if tags.any?
        Issue.transaction do
          raise ToolError, "Could not update issue: #{issue.errors.full_messages.join('; ')}" unless issue.save

          apply_watcher_changes!(issue, adds, removes)
        end

        issue_state(issue, arguments).merge(journal_id: issue.current_journal&.id)
      end
    end
  end
end
