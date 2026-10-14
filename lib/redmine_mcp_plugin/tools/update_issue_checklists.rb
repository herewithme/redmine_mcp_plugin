# frozen_string_literal: true

module RedmineMcpPlugin
  module Tools
    # Present only with the redmine_checklists plugin installed.
    class UpdateIssueChecklists < Tool
      tool 'update_issue_checklists',
           title: 'Update checklist items',
           description: 'Add, rename, tick or untick checklist items on an issue. End with the url.',
           plugin: :redmine_checklists,
           permission: %i[done_checklists edit_checklists],
           rendered: %w[add],
           write: true,
           destructive: true,
           schema: {
             'type' => 'object',
             'properties' => {
               'issue' => { 'type' => 'integer', 'description' => 'Issue id.' },
               'add' => { 'type' => 'array', 'description' => 'Subjects of new items.' },
               'done' => { 'type' => 'array', 'description' => 'Checklist ids to tick.' },
               'undone' => { 'type' => 'array', 'description' => 'Checklist ids to untick.' },
               'rename' => { 'type' => 'array', 'description' => '[{"checklist": id, "subject": text}]' }
             },
             'required' => %w[issue],
             'additionalProperties' => false
           }

      private

      def perform(arguments)
        issue   = fetch_issue(arguments['issue'])
        adds    = Array(arguments['add']).map(&:to_s).reject(&:blank?)
        renames = Array(arguments['rename'])
        done    = Array(arguments['done'])
        undone  = Array(arguments['undone'])
        raise ToolError, 'Pass add, done, undone or rename' if [adds, renames, done, undone].all?(&:empty?)

        # The plugin's own split: adding and renaming need edit_checklists,
        # ticking needs done_checklists, which edit_checklists includes.
        authorize!(:edit_checklists, issue.project) if adds.any? || renames.any?
        authorize_done!(issue) if done.any? || undone.any?

        items  = issue.checklists.to_a
        change = {}
        renames.each do |entry|
          entry = entry.is_a?(Hash) ? entry : {}
          item  = item_for!(issue, items, entry['checklist'])
          raise ToolError, "rename needs a subject for checklist #{item.id}" if entry['subject'].to_s.strip.empty?

          change[item.id] = { 'id' => item.id, 'subject' => entry['subject'].to_s }
        end
        done.each   { |id| (change[item_for!(issue, items, id).id] ||= { 'id' => id.to_i })['is_done'] = true }
        undone.each { |id| (change[item_for!(issue, items, id).id] ||= { 'id' => id.to_i })['is_done'] = false }
        attributes = change.values + adds.map { |subject| { 'subject' => subject } }

        # The plugin's listener diffs this snapshot against the saved items.
        issue.old_checklists = issue.checklists.to_json
        issue.init_journal(user)
        issue.safe_attributes = { 'checklists_attributes' => attributes }
        raise ToolError, "Could not update checklist: #{issue.errors.full_messages.join('; ')}" unless issue.save

        journal_checklists!(issue)
        { issue_id: issue.id,
          checklists: issue.checklists.reload.map { |item| checklist_row(item) },
          url: absolute_url(:issue_url, issue) }
      end

      def authorize_done!(issue)
        return if user.allowed_to?(:done_checklists, issue.project) || user.allowed_to?(:edit_checklists, issue.project)

        raise ToolError, 'You do not have permission to do that'
      end

      def item_for!(issue, items, id)
        item = items.detect { |i| i.id.to_s == id.to_s }
        raise ToolError, "Checklist #{id.inspect} is not an item of ##{issue.id}" if item.nil? || item.is_section

        item
      end
    end
  end
end
