require 'distributed_mutex'

module DiscourseNarrativeBot
  class NewUserNarrative < Base
    I18N_KEY = "discourse_narrative_bot.new_user_narrative".freeze
    BADGE_NAME = 'Certified'.freeze

    TRANSITION_TABLE = {
      begin: {
        init: {
          next_state: :tutorial_bookmark,
          next_instructions: Proc.new { I18n.t("#{I18N_KEY}.bookmark.instructions") },
          action: :say_hello
        }
      },

      tutorial_bookmark: {
        next_state: :tutorial_onebox,
        next_instructions: Proc.new { I18n.t("#{I18N_KEY}.onebox.instructions") },

        bookmark: {
          action: :reply_to_bookmark
        },

        reply: {
          next_state: :tutorial_bookmark,
          action: :missing_bookmark
        }
      },

      tutorial_onebox: {
        next_state: :tutorial_emoji,
        next_instructions: Proc.new { I18n.t("#{I18N_KEY}.emoji.instructions") },

        reply: {
          action: :reply_to_onebox
        }
      },

      tutorial_emoji: {
        next_state: :tutorial_mention,
        next_instructions: Proc.new {
          I18n.t("#{I18N_KEY}.mention.instructions", discobot_username: self.class.discobot_user.username)
        },
        reply: {
          action: :reply_to_emoji
        }
      },

      tutorial_mention: {
        next_state: :tutorial_formatting,
        next_instructions: Proc.new { I18n.t("#{I18N_KEY}.formatting.instructions") },

        reply: {
          action: :reply_to_mention
        }
      },

      tutorial_formatting: {
        next_state: :tutorial_quote,
        next_instructions: Proc.new { I18n.t("#{I18N_KEY}.quoting.instructions") },

        reply: {
          action: :reply_to_formatting
        }
      },

      tutorial_quote: {
        next_state: :tutorial_images,
        next_instructions: Proc.new { I18n.t("#{I18N_KEY}.images.instructions") },

        reply: {
          action: :reply_to_quote
        }
      },

      tutorial_images: {
        next_state: :tutorial_flag,
        next_instructions: Proc.new {
          I18n.t("#{I18N_KEY}.flag.instructions",
            guidelines_url: url_helpers(:guidelines_url),
            about_url: url_helpers(:about_index_url))
        },
        reply: {
          action: :reply_to_image
        },
        like: {
          action: :track_like
        }
      },

      tutorial_flag: {
        next_state: :tutorial_search,
        next_instructions: Proc.new { I18n.t("#{I18N_KEY}.search.instructions") },
        flag: {
          action: :reply_to_flag
        },
        reply: {
          next_state: :tutorial_flag,
          action: :missing_flag
        }
      },

      tutorial_search: {
        next_state: :end,
        reply: {
          action: :reply_to_search
        }
      }
    }

    SEARCH_ANSWER = ':herb:'.freeze

    def self.reset_trigger
      I18n.t('discourse_narrative_bot.new_user_narrative.reset_trigger')
    end

    def reset_bot(user, post)
      if pm_to_bot?(post)
        reset_data(user, { topic_id: post.topic_id })
      else
        reset_data(user)
      end

      Jobs.enqueue_in(2.seconds, :narrative_init, user_id: user.id, klass: self.class.to_s)
    end

    private

    def synchronize(user)
      if Rails.env.test?
        yield
      else
        DistributedMutex.synchronize("new_user_narrative_#{user.id}") { yield }
      end
    end

    def init_tutorial_search
      topic = @post.topic
      post = topic.first_post

      MessageBus.publish('/new_user_narrative/tutorial_search', {}, user_ids: [@user.id])

      raw = <<~RAW
      #{post.raw}

      #{I18n.t("#{I18N_KEY}.search.hidden_message")}
      RAW

      PostRevisor.new(post, topic).revise!(
        self.class.discobot_user,
        { raw: raw },
        { skip_validations: true, force_new_version: true }
      )

      set_state_data(:post_version, post.reload.version || 0)
    end

    def say_hello
      raw = I18n.t(
        "#{I18N_KEY}.hello.message",
        username: @user.username,
        title: SiteSetting.title
      )

      raw = <<~RAW
      #{raw}

      #{instance_eval(&@next_instructions)}
      RAW

      opts = {
        title: I18n.t("#{I18N_KEY}.hello.title", title: SiteSetting.title),
        target_usernames: @user.username,
        archetype: Archetype.private_message
      }

      if @post &&
         @post.archetype == Archetype.private_message &&
         @post.topic.topic_allowed_users.pluck(:user_id).include?(@user.id)

        opts = opts.merge(topic_id: @post.topic_id)
      end

      if @data[:topic_id]
        opts = opts.merge(topic_id: @data[:topic_id])
      end

      post = reply_to(@post, raw, opts)
      @data[:topic_id] = post.topic.id
      @data[:track] = self.class.to_s
      post
    end

    def missing_bookmark
      return unless valid_topic?(@post.topic_id)
      return if @post.user_id == self.class.discobot_user.id

      fake_delay
      enqueue_timeout_job(@user)
      reply_to(@post, I18n.t("#{I18N_KEY}.bookmark.not_found")) unless @data[:attempted]
      false
    end

    def reply_to_bookmark
      return unless valid_topic?(@post.topic_id)
      return unless @post.user_id == self.class.discobot_user.id

      raw = <<~RAW
        #{I18n.t("#{I18N_KEY}.bookmark.reply", profile_page_url: url_helpers(:user_url, username: @user.username))}

        #{instance_eval(&@next_instructions)}
      RAW

      fake_delay

      reply = reply_to(@post, raw)
      enqueue_timeout_job(@user)
      reply
    end

    def reply_to_onebox
      post_topic_id = @post.topic_id
      return unless valid_topic?(post_topic_id)

      @post.post_analyzer.cook(@post.raw, {})

      if @post.post_analyzer.found_oneboxes?
        raw = <<~RAW
          #{I18n.t("#{I18N_KEY}.onebox.reply")}

          #{instance_eval(&@next_instructions)}
        RAW

        fake_delay

        reply = reply_to(@post, raw)
        enqueue_timeout_job(@user)
        reply
      else
        fake_delay
        reply_to(@post, I18n.t("#{I18N_KEY}.onebox.not_found")) unless @data[:attempted]
        enqueue_timeout_job(@user)
        false
      end
    end

    def track_like
      post_topic_id = @post.topic_id
      return unless valid_topic?(post_topic_id)

      post_liked = PostAction.find_by(
        post_action_type_id: PostActionType.types[:like],
        post_id: @data[:last_post_id],
        user_id: @user.id
      )

      if post_liked
        set_state_data(:liked, true)

        if (post_id = get_state_data(:post_id)) && (post = Post.find_by(id: post_id))
          fake_delay
          like_post(post)

          raw = <<~RAW
            #{I18n.t("#{I18N_KEY}.images.reply")}

            #{instance_eval(&@next_instructions)}
          RAW

          reply = reply_to(@post, raw)
          enqueue_timeout_job(@user)
          return reply
        end
      end

      false
    end

    def reply_to_image
      post_topic_id = @post.topic_id
      return unless valid_topic?(post_topic_id)

      @post.post_analyzer.cook(@post.raw, {})
      transition = true
      attempted_count = get_state_data(:attempted) || 0

      if attempted_count < 2
        @data[:skip_attempted] = true
        @data[:attempted] = false
      else
        @data[:skip_attempted] = false
      end

      if @post.post_analyzer.image_count > 0
        set_state_data(:post_id, @post.id)

        if get_state_data(:liked)
          raw = <<~RAW
            #{I18n.t("#{I18N_KEY}.images.reply")}

            #{instance_eval(&@next_instructions)}
          RAW

          like_post(@post)
        else
          raw = I18n.t(
            "#{I18N_KEY}.images.like_not_found",
            url: Post.find_by(id: @data[:last_post_id]).url
          )

          transition = false
        end
      else
        raw = I18n.t(
          "#{I18N_KEY}.images.not_found",
          image_url: "#{Discourse.base_url}/images/dog-walk.gif"
        )

        transition = false
      end

      fake_delay

      set_state_data(:attempted, attempted_count + 1) if !transition
      reply = reply_to(@post, raw) unless @data[:attempted] && !transition
      enqueue_timeout_job(@user)
      transition ? reply : false
    end

    def reply_to_formatting
      post_topic_id = @post.topic_id
      return unless valid_topic?(post_topic_id)

      if Nokogiri::HTML.fragment(@post.cooked).css("b", "strong", "em", "i", ".bbcode-i", ".bbcode-b").size > 0
        raw = <<~RAW
          #{I18n.t("#{I18N_KEY}.formatting.reply")}

          #{instance_eval(&@next_instructions)}
        RAW

        fake_delay

        reply = reply_to(@post, raw)
        enqueue_timeout_job(@user)
        reply
      else
        fake_delay
        reply_to(@post, I18n.t("#{I18N_KEY}.formatting.not_found")) unless @data[:attempted]
        enqueue_timeout_job(@user)
        false
      end
    end

    def reply_to_quote
      post_topic_id = @post.topic_id
      return unless valid_topic?(post_topic_id)

      doc = Nokogiri::HTML.fragment(@post.cooked)

      if doc.css(".quote").size > 0
        raw = <<~RAW
          #{I18n.t("#{I18N_KEY}.quoting.reply")}

          #{instance_eval(&@next_instructions)}
        RAW

        fake_delay

        reply = reply_to(@post, raw)
        enqueue_timeout_job(@user)
        reply
      else
        fake_delay
        reply_to(@post, I18n.t("#{I18N_KEY}.quoting.not_found")) unless @data[:attempted]
        enqueue_timeout_job(@user)
        false
      end
    end

    def reply_to_emoji
      post_topic_id = @post.topic_id
      return unless valid_topic?(post_topic_id)

      doc = Nokogiri::HTML.fragment(@post.cooked)

      if doc.css(".emoji").size > 0
        raw = <<~RAW
          #{I18n.t("#{I18N_KEY}.emoji.reply")}

          #{instance_eval(&@next_instructions)}
        RAW

        fake_delay

        reply = reply_to(@post, raw)
        enqueue_timeout_job(@user)
        reply
      else
        fake_delay
        reply_to(@post, I18n.t("#{I18N_KEY}.emoji.not_found")) unless @data[:attempted]
        enqueue_timeout_job(@user)
        false
      end
    end

    def reply_to_mention
      post_topic_id = @post.topic_id
      return unless valid_topic?(post_topic_id)

      if bot_mentioned?(@post)
        raw = <<~RAW
          #{I18n.t("#{I18N_KEY}.mention.reply")}

          #{instance_eval(&@next_instructions)}
        RAW

        fake_delay

        reply = reply_to(@post, raw)
        enqueue_timeout_job(@user)
        reply
      else
        fake_delay

        unless @data[:attempted]
          reply_to(@post, I18n.t(
            "#{I18N_KEY}.mention.not_found",
            username: @user.username,
            discobot_username: self.class.discobot_user.username
          ))
        end

        enqueue_timeout_job(@user)
        false
      end
    end

    def missing_flag
      return unless valid_topic?(@post.topic_id)
      return if @post.user_id == -2

      fake_delay
      reply_to(@post, I18n.t("#{I18N_KEY}.flag.not_found")) unless @data[:attempted]
      false
    end

    def reply_to_flag
      post_topic_id = @post.topic_id
      return unless valid_topic?(post_topic_id)
      return unless @post.user.id == -2

      raw = <<~RAW
        #{I18n.t("#{I18N_KEY}.flag.reply")}

        #{instance_eval(&@next_instructions)}
      RAW

      fake_delay

      reply = reply_to(@post, raw)
      @post.post_actions.where(user_id: @user.id).destroy_all

      enqueue_timeout_job(@user)
      reply
    end

    def reply_to_search
      post_topic_id = @post.topic_id
      return unless valid_topic?(post_topic_id)

      if @post.raw.match(/#{SEARCH_ANSWER}/)
        fake_delay

        reply = reply_to(@post, I18n.t("#{I18N_KEY}.search.reply", search_url: url_helpers(:search_url)))

        first_post = @post.topic.first_post
        first_post.revert_to(get_state_data(:post_version) - 1)
        first_post.save!
        first_post.publish_change_to_clients! :revised

        reply
      else
        fake_delay
        reply_to(@post, I18n.t("#{I18N_KEY}.search.not_found")) unless @data[:attempted]
        enqueue_timeout_job(@user)
        false
      end
    end

    def end_reply
      fake_delay

      reply_to(
        @post,
        I18n.t("#{I18N_KEY}.end.message",
          username: @user.username,
          base_url: Discourse.base_url,
          certificate: certificate,
          discobot_username: self.class.discobot_user.username,
          advanced_trigger: AdvancedUserNarrative.reset_trigger
        ),
        topic_id: @data[:topic_id]
      )
    end

    def like_post(post)
      PostAction.act(self.class.discobot_user, post, PostActionType.types[:like])
    end

    def welcome_topic
      Topic.find_by(slug: 'welcome-to-discourse', archetype: Archetype.default) ||
        Topic.recent(1).first
    end

    def url_helpers(url, opts = {})
      Rails.application.routes.url_helpers.send(url, opts.merge(host: Discourse.base_url))
    end
  end
end
