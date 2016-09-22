# encoding: utf-8
require 'sinatra'
require 'json'
require 'httparty'
require 'redis'
require 'dotenv'
require 'text'
require 'sanitize'

configure do
  # Load .env vars
  Dotenv.load
  # Disable output buffering
  $stdout.sync = true
  
  # Set up redis
  case settings.environment
  when :development
    uri = URI.parse(ENV['LOCAL_REDIS_URL'])
  when :production
    uri = URI.parse(ENV['REDISCLOUD_URL'])
  end
  $redis = Redis.new(host: uri.host, port: uri.port, password: uri.password)
end

# Handles the POST request made by the Slack Outgoing webhook
# Params sent in the request:
# 
# token=abc123
# team_id=T0001
# channel_id=C123456
# channel_name=test
# timestamp=1355517523.000005
# user_id=U123456
# user_name=Steve
# text=trebekbot jeopardy me
# trigger_word=trebekbot
# 
post '/' do
  response = ''
  begin
    puts "[LOG] #{params}"
    #params[:text] = params[:text].sub(params[:trigger_word], "").strip 
    if params[:token] != ENV['OUTGOING_WEBHOOK_TOKEN']
      response = 'Invalid token'
    elsif is_channel_blacklisted?(params[:channel_name])
      response = "Sorry, can't play in this channel."

    #forgebot params
    elsif params[:text].match(/!a /)
      response = process_answer(params)
    elsif params[:text].match(/!t$/i)
      response = respond_with_question(params)
    elsif params[:text].match(/!h$/i)
      response = respond_with_hint
    elsif params[:text].match(/!skip$/i)
      response = skip(params)
      response += respond_with_question(params)
    elsif params[:text].match(/!top$/i)
      response = respond_with_leaderboard

    #Admin commands
    elsif params[:text].match(/reset$/i)
      if is_user_admin_or_err?(params[:user_name])
        response = respond_with_leaderboard(true)
        response += "\n\nStarting a new round of jeopardy"
        reset_leaderboard(params[:channel_id])
      end

    #Original commands
    elsif params[:text].match(/help$/i)
      response = respond_with_help
    elsif params[:text].match(/jeopardy me/i)
      response = respond_with_question(params)
    elsif params[:text].match(/my score$/i)
      response = respond_with_user_score(params[:user_id])
    elsif params[:text].match(/show (me\s+)?(the\s+)?leaderboard$/i)
      response = respond_with_leaderboard
    elsif params[:text].match(/show (me\s+)?(the\s+)?loserboard$/i)
      response = respond_with_loserboard
    end
  rescue => e
    puts "[ERROR] #{e}"
    response = ''
  end
  status 200
  body json_response_for_slack(response)
end

# Puts together the json payload that needs to be sent back to Slack
# 
def json_response_for_slack(reply)
  response = { text: reply, link_names: 1 }
  response[:username] = ENV['BOT_USERNAME'] unless ENV['BOT_USERNAME'].nil?
  response[:icon_emoji] = ENV['BOT_ICON'] unless ENV['BOT_ICON'].nil?
  response.to_json
end

# Determines if a game of Jeopardy is allowed in the given channel
# 
def is_channel_blacklisted?(channel_name)
  !ENV['CHANNEL_BLACKLIST'].nil? && ENV['CHANNEL_BLACKLIST'].split(',').find{ |a| a.gsub('#', '').strip == channel_name }
end

# Defines if a given user is allowed to administer the channel
#
def is_user_admin?(user_name)
  isadmin = !ENV['ADMIN_USERS'].nil? && ENV['ADMIN_USERS'].split(',').find{ |u| u == user_name }
  puts "[LOG] Testing whether #{user_name} is an admin against #{ENV['ADMIN_USERS']}, result is #{isadmin ? 'true' : 'false'}"
  isadmin
end

def is_user_admin_or_err?(user_name)
  isadmin = is_user_admin?(user_name)
  unless isadmin
    puts '[LOG] That command requires admin privileges, which you don\'t have'
  end
  isadmin
end

def skip(params)
  key = "current_question:#{params[:channel_id]}"
  previous_question = $redis.get(key)
  if previous_question.nil?
    "There was no active question. Here's a new one:\n"
  else
    previous_answer = JSON.parse(previous_question)['answer']
    answer = "The answer is `#{previous_answer}`.\n"
    mark_question_as_answered(params[:channel_id])
    answer
  end
end

# Puts together the response to a request to start a new round (`jeopardy me`):
# If the bot has been "shushed", says nothing.
# If there's an existing question, repeats it.
# Otherwise, speaks the category, value, and the new question, and shushes the bot for 5 seconds
# (this is so two or more users can't do `jeopardy me` within 5 seconds of each other.)
# 
def respond_with_question(params)
  channel_id = params[:channel_id]
  question = ''
  unless $redis.exists("shush:question:#{channel_id}")
    key = "current_question:#{channel_id}"
    previous_question = $redis.get(key)
    if !previous_question.nil?
      previous_question = JSON.parse(previous_question)
      question = type_question(previous_question)
    else
      response = get_question
      question += type_question(response)
      puts "[LOG] ID: #{response['id']} | Category: #{response['category']['title']} | Question: #{response['question']} | Answer: #{response['answer']} | Value: #{response['value']}"
      $redis.pipelined do
        $redis.set(key, response.to_json)
        $redis.setex("shush:question:#{channel_id}", 10, 'true')
      end
    end
  end
  question
end

def respond_with_hint
  reply = ''
  channel_id = params[:channel_id]
  key = "current_question:#{channel_id}"
  current_question = $redis.get(key)
  if current_question.nil?
    reply = trebek_me unless $redis.exists("shush:answer:#{channel_id}")
  else
    current_question = JSON.parse(current_question)
    current_answer = current_question['answer']
    hint_count = get_hint_count_value + 1
    $redis.set(get_hint_key, hint_count.to_s)
    reply = current_answer[0,hint_count].ljust(current_answer.length, '.') + " (hints used: #{hint_count})"
  end
  reply
end

def get_hint_key
  key = "current_question:#{params[:channel_id]}"
  key + ':hint_count'
end

def get_hint_count_value
  hint_key = get_hint_key
  if $redis.exists(hint_key)
    hint_count = $redis.get(hint_key).to_i
  else
    hint_count = 0
  end
  hint_count
end

# Gets a random answer from the jService API, and does some cleanup on it:
# If the question is not present, requests another one
# If the answer doesn't have a value, sets a default of $200
# If there's HTML in the answer, sanitizes it (otherwise it won't match the user answer)
# Adds an "expiration" value, which is the timestamp of the Slack request + the seconds to answer config var
# 
def get_question
  uri = 'http://jservice.io/api/random?count=1'
  request = HTTParty.get(uri)
  puts "[LOG] #{request.body}"
  response = JSON.parse(request.body).first
  # Some questions have no question, some have been marked invalid by the admin
  if response['question'].nil? || response['question'].strip == '' ||
     (!response['invalid_count'].nil? && response['invalid_count'].to_i > 0)
    response = get_question
  end
  response['value'] = 200 if response['value'].nil?
  response['answer'] = Sanitize.fragment(response['answer'].gsub(/\s+(&nbsp;|&)\s+/i, ' and '))
  response['expiration'] = params['timestamp'].to_f + ENV['SECONDS_TO_ANSWER'].to_f
  response
end

# Formats the question for user display
def type_question(question)
  "The category is `#{question['category']['title']}` for #{currency_format(question['value'])}: `#{question['question']}`"
end

# Processes an answer submitted by a user in response to a Jeopardy round:
# If there's no round, returns a funny SNL Trebek quote.
# Otherwise, responds appropriately if:
# The user already tried to answer;
# The time to answer the round is up;
# The answer is correct and in the form of a question;
# The answer is correct and not in the form of a question;
# The answer is incorrect.
# Update the score and marks the round as answer, depending on the case.
# 
def process_answer(params)
  channel_id = params[:channel_id]
  user_id = params[:user_id]
  key = "current_question:#{channel_id}"
  current_question = $redis.get(key)
  reply = ''
  if current_question.nil?
    reply = trebek_me unless $redis.exists("shush:answer:#{channel_id}")
  else
    current_question = JSON.parse(current_question)
    current_answer = current_question['answer']
    user_answer = params[:text]
    answered_key = "user_answer:#{channel_id}:#{current_question['id']}:#{user_id}"
    if params['timestamp'].to_f > current_question['expiration']
      if is_correct_answer?(current_answer, user_answer)
        reply = "That is correct, #{get_slack_name(user_id)}, but time's up! Remember, you have #{ENV['SECONDS_TO_ANSWER']} seconds to answer."
      else
        reply = "Time's up, #{get_slack_name(user_id)}! Remember, you have #{ENV['SECONDS_TO_ANSWER']} seconds to answer. The correct answer is `#{current_question['answer']}`."
      end
      mark_question_as_answered(params[:channel_id])

    elsif is_correct_answer?(current_answer, user_answer)
      adjusted_points = get_adjusted_points(current_question['value'])
      score = update_score(user_id, adjusted_points)
      earned_str = "#{currency_format(adjusted_points)}"
      if adjusted_points != current_question['value']
        earned_str = earned_str + " (adjusted from: #{currency_format(current_question['value'])})"
      end
      reply = "That is correct, *#{get_slack_name(user_id)}*. The answer was `#{current_answer}`. You have earned #{earned_str}. Your total score is #{currency_format(score)}."
      mark_question_as_answered(params[:channel_id])
    else
      reply = "#{clean_incorrect(user_answer)} is incorrect, #{get_slack_name(user_id)}."
      $redis.setex(answered_key, ENV['SECONDS_TO_ANSWER'], 'true')
    end
  end
  reply
end

def get_adjusted_points(original_points)
  # reduce by 100 each time, min 100
  adjusted_points = original_points
  hint_count = get_hint_count_value
  adjusted_points = adjusted_points - (hint_count * 100)
  [adjusted_points, 100].max
end

def clean_incorrect(incorrect_answer)
  incorrect_answer.sub('!a', '').strip
end

# Formats a number as currency.
# For example -10000 becomes -$10,000
# 
def currency_format(number, currency = '$')
  prefix = number >= 0 ? currency : "-#{currency}"
  moneys = number.abs.to_s
  while moneys.match(/(\d+)(\d\d\d)/)
    moneys.to_s.gsub!(/(\d+)(\d\d\d)/, "\\1,\\2")
  end
  "#{prefix}#{moneys}"
end

# Checks if the respose is in the form of a question:
# Removes punctuation and check if it begins with what/where/who
# (I don't care if there's no question mark)
# 
def is_question_format?(answer)
  answer.gsub(/[^\w\s]/i, '').match(/^(what|whats|where|wheres|who|whos) /i)
end

# Checks if the user answer matches the correct answer.
# Does processing on both to make matching easier:
# Replaces "&" with "and";
# Removes punctuation;
# Removes question elements ("what is a")
# Strips leading/trailing whitespace and downcases.
# Finally, if the match is not exact, uses White similarity algorithm for "fuzzy" matching,
# to account for typos, etc.
# 
def is_correct_answer?(correct, answer)
  correct = correct.gsub(/[^\w\s]/i, '')
            .gsub(/^(the|a|an) /i, '')
            .strip
            .downcase
  answer = answer
           .gsub(/\s+(&nbsp;|&)\s+/i, ' and ')
           .gsub(/[^\w\s]/i, '')
           .gsub(/^(what|whats|where|wheres|who|whos) /i, '')
           .gsub(/^(is|are|was|were) /, '')
           .gsub(/^(the|a|an) /i, '')
           .gsub(/\?+$/, '')
           .strip
           .downcase
  white = Text::WhiteSimilarity.new
  similarity = white.similarity(correct, answer)
  puts "[LOG] Correct answer: #{correct} | User answer: #{answer} | Similarity: #{similarity}"
  correct == answer || similarity >= ENV['SIMILARITY_THRESHOLD'].to_f
end

# Marks question as answered by:
# Deleting the current question from redis,
# and "shushing" the bot for 5 seconds, so if two users
# answer at the same time, the second one won't trigger
# a response from the bot.
# 
def mark_question_as_answered(channel_id)
  $redis.pipelined do
    $redis.del("current_question:#{channel_id}")
    $redis.del("current_question:#{channel_id}:hint_count")
    $redis.del("shush:question:#{channel_id}")
    $redis.setex("shush:answer:#{channel_id}", 5, 'true')
  end
end

# Resets all scores and any active question/answer
#
def reset_leaderboard(channel_id)
  $redis.del(*$redis.keys("*:#{channel_id}*"))
  $redis.del(*$redis.keys('user_score:*'))
  $redis.del(*['leaderboard:1', 'loserboard:1'])
end

# Returns the given user's score.
# 
def respond_with_user_score(user_id)
  user_score = get_user_score(user_id)
  "#{get_slack_name(user_id)}, your score is #{currency_format(user_score)}."
end

# Gets the given user's score from redis
# 
def get_user_score(user_id)
  key = "user_score:#{user_id}"
  user_score = $redis.get(key)
  if user_score.nil?
    $redis.set(key, 0)
    user_score = 0
  end
  user_score.to_i
end

# Updates the given user's score in redis.
# If the user doesn't have a score, initializes it at zero.
# 
def update_score(user_id, score = 0)
  key = "user_score:#{user_id}"
  user_score = $redis.get(key)
  if user_score.nil?
    $redis.set(key, score)
    score
  else
    new_score = user_score.to_i + score
    $redis.set(key, new_score)
    new_score
  end
end

# Gets the given user's name(s) from redis.
# If it's not in redis, makes an API request to Slack to get it,
# and caches it in redis for a month.
# 
# Options:
# use_real_name => returns the users full name instead of just the first name
# 
def get_slack_name(user_id, options = {})
  options = { :use_real_name => false }.merge(options)
  key = "slack_user_names:2:#{user_id}"
  names = $redis.get(key)
  if names.nil?
    names = get_slack_names_hash(user_id)
    $redis.setex(key, 60*60*24*30, names.to_json)
  else
    names = JSON.parse(names)
  end
  if options[:use_real_name]
    name = names['real_name'].nil? ? names['name'] : names['real_name']
  else
    name = names['first_name'].nil? ? names['name'] : names['first_name']
  end
  name
end

# Makes an API request to Slack to get a user's set of names.
# (Slack's outgoing webhooks only send the user ID, so we need this to
# make the bot reply using the user's actual name.)
# 
def get_slack_names_hash(user_id)
  uri = "https://slack.com/api/users.list?token=#{ENV['API_TOKEN']}"
  request = HTTParty.get(uri)
  response = JSON.parse(request.body)
  if response['ok']
    user = response['members'].find { |u| u['id'] == user_id }
    names = { :id => user_id, :name => user['name']}
    unless user['profile'].nil?
      names['real_name'] = user['profile']['real_name'] unless user['profile']['real_name'].nil? || user['profile']['real_name'] == ''
      names['first_name'] = user['profile']['first_name'] unless user['profile']['first_name'].nil? || user['profile']['first_name'] == ''
      names['last_name'] = user['profile']['last_name'] unless user['profile']['last_name'].nil? || user['profile']['last_name'] == ''
    end
  else
    names = { :id => user_id, :name => 'Sean Connery'}
  end
  names
end

# Speaks the top scores across Slack.
# The response is cached for 5 minutes.
# 
def respond_with_leaderboard(is_final = false)
  key = 'leaderboard:1'
  response = $redis.get(key)
  if response.nil?
    leaders = []
    get_score_leaders.each_with_index do |leader, i|
      user_id = leader[:user_id]
      name = get_slack_name(leader[:user_id], { :use_real_name => true })
      score = currency_format(get_user_score(user_id))
      leaders << "#{i + 1}. #{name}: #{score}"
    end
    if leaders.size > 0
      if is_final == true
        response = 'The final scores for this round are:'
      else
        response = "Let's take a look at the top scores:"
      end
      response += "\n\n#{leaders.join("\n")}"
    else
      response = 'There are no scores yet!'
    end
    $redis.setex(key, 60*5, response)
  end
  response
end

# Speaks the bottom scores across Slack.
# The response is cached for 15 seconds.
# 
def respond_with_loserboard
  key = 'loserboard:1'
  response = $redis.get(key)
  if response.nil?
    leaders = []
    get_score_leaders({ :order => 'asc'}).each_with_index do |leader, i|
      user_id = leader[:user_id]
      name = get_slack_name(leader[:user_id], { :use_real_name => true })
      score = currency_format(get_user_score(user_id))
      leaders << "#{i + 1}. #{name}: #{score}"
    end
    if leaders.size > 0
      response = "Let's take a look at the bottom scores:\n\n#{leaders.join("\n")}"
    else
      response = 'There are no scores yet!'
    end
    $redis.setex(key, 15, response)
  end
  response
end

# Gets N scores from redis, with optional sorting.
# 
def get_score_leaders(options = {})
  options = { :limit => 10, :order => 'desc'}.merge(options)
  leaders = []
  $redis.scan_each(:match => 'user_score:*'){ |key| user_id = key.gsub('user_score:', ''); leaders << {:user_id => user_id, :score => get_user_score(user_id) } }
  puts "[LOG] Leaderboard: #{leaders.to_s}"
  if leaders.size > 1
    if options[:order] == 'desc'
      leaders = leaders.uniq{ |l| l[:user_id] }.sort{ |a, b| b[:score] <=> a[:score] }.slice(0, options[:limit])
    else
      leaders = leaders.uniq{ |l| l[:user_id] }.sort{ |a, b| a[:score] <=> b[:score] }.slice(0, options[:limit])
    end
  end
  leaders
end

# When someone invokes trebekbot and there's no active question,
# prompt them, don't insult them.
# 
def trebek_me
  'There is no active question. Type "!t" to get a question.'
end

# Shows the help text.
# If you add a new command, make sure to add some help text for it here.
# 
def respond_with_help
  reply = <<help
Type `!t` to start a new round of Slack Jeopardy. I will pick the category and price. Anyone in the channel can respond.
Type `!a` to respond to the active question. You have #{ENV['SECONDS_TO_ANSWER']} seconds to answer.
Type `!h` to get a one-letter hint. This reduces the value of the question by $100.
Type `!skip` to skip the current question, see the answer, and get a new question.
Type `!top` to see the top scores.
Type `#{ENV['BOT_USERNAME']} what is my score` to see your current score.
Type `#{ENV['BOT_USERNAME']} show the loserboard` to see the bottom scores.
help
  reply
end
