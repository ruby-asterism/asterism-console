# The page asks the bridge to measure topic rates (RateLease): "*" while
# "Measure all topics" is on, a topic id while its details are open. The
# page renews every 10 s; a lease lasts 30 s.
class RatesController < ApplicationController
  def create
    lease = RateLease.renew(params[:topic].to_s)
    if lease
      render json: { "key" => lease.key, "expires_at" => lease.expires_at }, status: :created
    else
      render json: { "errors" => [ "not a topic: #{params[:topic].to_s[0, 80]}" ] }, status: :unprocessable_content
    end
  end
end
