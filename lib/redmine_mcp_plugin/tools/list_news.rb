# frozen_string_literal: true

module RedmineMcpPlugin
  module Tools
    class ListNews < Tool
      tool 'list_news',
           title: 'List news',
           description: 'List project news visible to the authenticated user, newest first. Rows carry ' \
                        'the summary; pass include_description for the full text of each item, which ' \
                        'is cheaper than get_news per item.',
           permission: :view_news,
           schema: {
             'type' => 'object',
             'properties' => {
               'project' => { 'type' => %w[string integer],
                              'description' => 'Restrict to one project (identifier or numeric id).' },
               'from' => { 'type' => 'string', 'description' => 'Only news created on or after this ISO-8601 date.' },
               'to' => { 'type' => 'string', 'description' => 'Only news created on or before this ISO-8601 date.' },
               'include_description' => { 'type' => 'boolean',
                                          'description' => 'Include the full description of each item. Defaults to false.' },
               'offset' => { 'type' => 'integer', 'minimum' => 0,
                             'description' => 'Rows to skip, for paging past the server cap. Defaults to 0.' },
               'limit' => { 'type' => 'integer', 'minimum' => 1, 'description' => 'Maximum items to return.' }
             },
             'additionalProperties' => false
           }

      private

      def perform(arguments)
        scope = News.visible(user)
        if arguments['project'].present?
          project = fetch_project(arguments['project'])
          require_module!(project, :news)
          authorize!(:view_news, project)
          # Core's own index: the project's news, not its subprojects'.
          scope = project.news.visible(user)
        end
        scope = within_dates(scope, arguments)

        limit  = limit_for(arguments)
        offset = offset_for(arguments)
        rows   = scope.preload(:author, :project).order(created_on: :desc, id: :desc)
                      .offset(offset).limit(limit)
                      .map { |news| summarise(news, arguments['include_description']) }
        paged(total: scope.count, offset: offset, key: :news, rows: rows)
      end

      def within_dates(scope, arguments)
        from = Date.iso8601(iso_date(arguments['from'], 'from')) if arguments['from'].present?
        to   = Date.iso8601(iso_date(arguments['to'], 'to'))     if arguments['to'].present?
        raise ToolError, 'from must not be after to' if from && to && from > to

        created = News.arel_table[:created_on]
        scope = scope.where(created.gteq(from)) if from
        scope = scope.where(created.lt(to + 1)) if to
        scope
      end

      def summarise(news, with_description)
        row = {
          id: news.id,
          title: news.title,
          summary: news.summary,
          author: news.author && { id: news.author_id, name: news.author.name },
          created_on: iso(news.created_on),
          project: news.project && { id: news.project_id, identifier: news.project.identifier,
                                     name: news.project.name },
          comments_count: news.comments_count
        }
        row[:description] = news.description if with_description
        row
      end
    end
  end
end
