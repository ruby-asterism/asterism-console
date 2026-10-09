# Every page and request needs a signed-in user, except the sign-in pages
# themselves (allow_unauthenticated_access). There is no setting that turns
# this off. Action Cable checks the same cookie (ApplicationCable::Connection).
module Authentication
  extend ActiveSupport::Concern

  included do
    before_action :require_authentication
    helper_method :authenticated?, :current_user
  end

  class_methods do
    def allow_unauthenticated_access(**options)
      skip_before_action :require_authentication, **options
    end

    def require_admin(**options)
      before_action :require_admin, **options
    end
  end

  private
    def authenticated?
      resume_session
    end

    def current_user
      Current.user
    end

    def require_authentication
      resume_session || request_authentication
    end

    def require_admin
      return if current_user&.admin?
      respond_to do |f|
        f.html { redirect_to root_path, alert: "Only an admin can do that." }
        f.any { render json: { "errors" => [ "only an admin can do that" ] }, status: :forbidden }
      end
    end

    def resume_session
      Current.session ||= find_session_by_cookie
    end

    def find_session_by_cookie
      Session.live(cookies.signed[:session_id])
    end

    # Pages go to the sign-in page; JSON and the rest get 401.
    def request_authentication
      if request.format.html?
        session[:return_to_after_authenticating] = request.url if request.get?
        redirect_to new_session_path
      else
        head :unauthorized
      end
    end

    def after_authentication_url
      session.delete(:return_to_after_authenticating) || root_url
    end

    def start_new_session_for(user)
      reset_session # a fresh Rails session (no fixation)
      user.sessions.create!(user_agent: request.user_agent, ip_address: request.remote_ip).tap do |s|
        Current.session = s
        cookies.signed[:session_id] = { value: s.id, httponly: true, same_site: :lax,
                                        expires: Session::LIFETIME.from_now, secure: request.ssl? }
      end
    end

    def terminate_session
      Current.session&.destroy
      cookies.delete(:session_id)
    end
end
