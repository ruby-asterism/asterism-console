# The page asks the bridge to read a meta or call a method. The answer
# comes over Action Cable; show is there for polling and the tests.
#
# Only what a CallPermission allows goes to the bridge. Anything else is
# kept as "denied" (the call log shows it) and answered with 403.
class BridgeRequestsController < ApplicationController
  def create
    req = BridgeRequest.new(
      kind: params[:kind], path: params[:path], method_name: params[:method_name].presence,
      args: json_param(:args, "[]"), kwargs: json_param(:kwargs, "{}"),
      timeout_s: params[:timeout_s].presence || 2.0, user: current_user
    )
    unless req.valid?
      return render json: { "errors" => req.errors.full_messages }, status: :unprocessable_content
    end
    if req.permitted?
      req.save!
      render json: req.as_payload, status: :created
    else
      req.deny! # saves it: the log keeps what was refused
      render json: req.as_payload, status: :forbidden
    end
  end

  def show
    render json: BridgeRequest.find(params[:id]).as_payload
  end

  private

  # Arguments arrive as JSON text (what the user typed) or as JSON values.
  def json_param(name, default)
    v = params[name]
    return default if v.blank?
    v.is_a?(String) ? v : JSON.generate(v.respond_to?(:to_unsafe_h) ? v.to_unsafe_h : v)
  end
end
