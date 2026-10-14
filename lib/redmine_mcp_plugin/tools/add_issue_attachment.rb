# frozen_string_literal: true

module RedmineMcpPlugin
  module Tools
    class AddIssueAttachment < Tool
      tool 'add_issue_attachment',
           title: 'Attach a text file to an issue',
           description: 'Attach a text file to an issue. Notifies watchers as an issue update. End with the url.',
           permission: %i[edit_issues edit_own_issues add_issue_notes],
           plain: %w[description],
           write: true,
           schema: {
             'type' => 'object',
             'properties' => {
               'issue' => { 'type' => 'integer', 'description' => 'Issue id.' },
               'filename' => { 'type' => 'string', 'description' => 'With extension, e.g. report.md.' },
               'content' => { 'type' => 'string', 'description' => 'The file text.' },
               'description' => { 'type' => 'string' }
             },
             'required' => %w[issue filename content],
             'additionalProperties' => false
           }

      private

      def perform(arguments)
        issue = fetch_issue(arguments['issue'])
        authorize_attachment!(issue)
        content = arguments['content'].to_s.b
        raise ToolError, 'content must not be empty' if content.empty?

        # Core's upload path: the file first, then the issue takes it by token.
        # save_attachments sets the description from the token hash, so it goes there.
        attachment = Attachment.new(file: content, author: user)
        attachment.filename     = arguments['filename'].to_s
        attachment.content_type = Redmine::MimeType.of(attachment.filename) || 'text/plain'
        raise ToolError, "Could not attach: #{attachment.errors.full_messages.join('; ')}" unless attachment.valid?

        issue.init_journal(user)
        Issue.transaction do
          attachment.save!
          issue.save_attachments([{ 'token' => attachment.token, 'description' => arguments['description'].to_s }])
          raise ToolError, "Could not attach: #{issue.errors.full_messages.join('; ')}" unless issue.save
        end

        attachment_row(attachment).merge(issue_id: issue.id, journal_id: issue.current_journal&.id,
                                         issue_url: absolute_url(:issue_url, issue))
      end

      # Core's rule is attributes_editable? or notes_addable?, per tracker; the
      # scope-aware allowed_to? on the same three permissions comes first.
      def authorize_attachment!(issue)
        scoped = user.allowed_to?(:edit_issues, issue.project) ||
                 (issue.author_id == user.id && user.allowed_to?(:edit_own_issues, issue.project)) ||
                 user.allowed_to?(:add_issue_notes, issue.project)
        raise ToolError, 'You do not have permission to do that' unless scoped && issue.attachments_addable?(user)
      end
    end
  end
end
