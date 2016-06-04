#!/usr/bin/env ruby

# Send an email reminder to water every 5 days when it has not rained for at least 5 days. Designed to be
# scheduled via cron to run once a day. The host system must be able to send outgoing email via the "mail" command.
#
# Relevant API docs here:
# http://www.ncdc.noaa.gov/cdo-web/webservices/v2

@debug = false
email = nil
location_id = nil
token = nil

require "optparse"

OptionParser.new do |opts|
  opts.banner = "Usage: remind-me-to-water.rb [options]"

  opts.on("-d", "--debug", "Print debug messages") do
    @debug = true
  end

  opts.on("-e", "--email EMAIL", "Email to send the message to") do |input_email|
    email = input_email
  end

  opts.on("-l", "--locationid LOCATIONID", "Location ID of the location to check for rain (e.g. 'CITY:US270013')") do |input_location_id|
    location_id = input_location_id
  end

  opts.on("-t", "--token TOKEN", "Token for the NCDC API") do |input_token|
    token = input_token
  end

  opts.on_tail("-h", "--help", "Show the help message") do
    puts opts
    exit
  end
end.parse!

abort "email, locationid and token must be supplied!" unless email && location_id && token

def log(message)
  return unless @debug
  puts message
end

require "date"
require "json"
require "net/http"

HOW_OFTEN_DAYS = 5
PRECIP_THRESHOLD_INCHES = 0.1
DAYS_TO_CHECK = 30
PAGE_SIZE = 1000

offset = 1
result_count = nil

today = Date.today
watering_season_start = Date.new today.year, 5, 1
watering_season_end = Date.new today.year, 11, 1

unless today > watering_season_start && today < watering_season_end
  log "Not making any calls since it's not watering season"
  exit 0
end

from = (today - DAYS_TO_CHECK).iso8601
to = today.iso8601

results_by_date = {}

uri_format = "https://www.ncdc.noaa.gov/cdo-web/api/v2/data?datasetid=GHCND&locationid=#{location_id}&datatypeid=PRCP&startdate=#{from}&enddate=#{to}&limit=#{PAGE_SIZE}&offset=%d&units=standard"

uri = URI(uri_format % offset)

Net::HTTP.start(uri.host, uri.port, use_ssl: true) do |https|
  begin
    log "Getting results with offset #{offset}"

    req = Net::HTTP::Get.new(uri)
    req["token"] = token
    response = https.request req

    parsed_response = JSON.parse response.body

    result_count = parsed_response["metadata"]["resultset"]["count"]
    offset += PAGE_SIZE

    response_results_by_date = parsed_response["results"].group_by { |result| result["date"] }

    response_results_by_date.each_pair do |date, results|
      results_by_date[date] ||= []
      results_by_date[date] += results
    end

    uri = URI(uri_format % offset)
  end while offset < result_count
end

days_since_rain = results_by_date.keys.sort.reverse.find_index do |date|
  results_for_date = results_by_date[date]
  precip_readings = results_for_date.map { |result_for_date| result_for_date["value"] }
  average_precip = precip_readings.reduce(&:+) / precip_readings.size
  log "#{date} precip: #{average_precip}"
  average_precip > PRECIP_THRESHOLD_INCHES
end

log "It hasn't rained in #{days_since_rain} days"

if days_since_rain > 0 && days_since_rain % HOW_OFTEN_DAYS == 0
  require 'shellwords'
  subject = Shellwords.escape "Watering Reminder"
  body = Shellwords.escape "It hasn't rained in #{days_since_rain} days, you need to water!"

  result = system "/bin/echo #{body} | /usr/bin/mail --subject #{subject} #{email}"
  abort "remind-me-to-water: sending email failed!" unless result
end
