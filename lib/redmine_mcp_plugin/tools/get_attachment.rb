# frozen_string_literal: true

module RedmineMcpPlugin
  module Tools
    class GetAttachment < Tool
      tool 'get_attachment',
           title: 'Get attachment',
           description: 'Fetch an attachment\'s metadata and, for a text file within the display limit, its content.',
           permission: :view_issues,
           schema: {
             'type' => 'object',
             'properties' => {
               'attachment' => { 'type' => 'integer', 'description' => 'Attachment id, from get_issue.' }
             },
             'required' => %w[attachment],
             'additionalProperties' => false
           }

      private

      def perform(arguments)
        attachment = Attachment.find_by(id: arguments['attachment'].to_i)
        # Core's rule: visible when its container is, under the container's own permission.
        if attachment.nil? || !attachment.visible?(user)
          raise ToolError, "No visible attachment with id #{arguments['attachment'].inspect}"
        end

        row   = attachment_row(attachment)
        limit = Setting.file_max_size_displayed.to_i
        if !attachment.is_text?
          row[:content_omitted] = 'binary'
        elsif attachment.filesize > limit.kilobytes
          row[:content_omitted] = "larger than #{limit} KB"
        elsif !attachment.readable?
          row[:content_omitted] = 'file missing on disk'
        else
          # Read and converted the way core shows a text file inline.
          row[:content] = Redmine::CodesetUtil.to_utf8_by_setting(File.read(attachment.diskfile, mode: 'rb'))
        end
        row
      end
    end
  end
end
