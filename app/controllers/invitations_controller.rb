# Opening an invitation (W4): the only way to become a user besides the
# command line (bin/rails console:user). The link's token is checked on
# both steps; a closed, expired or unknown one shows the same page.
class InvitationsController < ApplicationController
  allow_unauthenticated_access
  rate_limit to: 10, within: 10.minutes, only: :update, store: RateLimits::STORE,
             with: -> { redirect_to new_session_path, alert: "Try again later." }
  layout "plain"

  def show
    @invitation = Invitation.find_open(params[:token])
    return render :closed, status: :not_found unless @invitation
    response.headers["Cache-Control"] = "no-store"
    response.headers["Referrer-Policy"] = "no-referrer"
  end

  def update
    @invitation = Invitation.find_open(params[:token])
    return render :closed, status: :not_found unless @invitation
    user = @invitation.accept!(**params.expect(user: %i[email_address password password_confirmation]).to_h.symbolize_keys)
    Rails.logger.info("invitation: #{@invitation.id} made #{user.email_address}#{' (admin)' if user.admin?}")
    start_new_session_for(user)
    redirect_to user.admin? ? account_path : root_path, notice: "Welcome. You are signed in."
  rescue ActiveRecord::RecordInvalid => e
    @error = e.record.errors.full_messages.to_sentence
    render :show, status: :unprocessable_content
  rescue ActiveRecord::RecordNotFound
    render :closed, status: :not_found
  end
end
