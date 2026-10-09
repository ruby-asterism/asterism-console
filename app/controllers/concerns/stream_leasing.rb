# The lease endpoints of the plot and log pages (StreamLease): the page
# sends everything it wants every few seconds (lease), and says when it
# closes (release, also as navigator.sendBeacon from pagehide).
module StreamLeasing
  extend ActiveSupport::Concern

  def lease
    leases, errors = StreamLease.renew_page(kind: lease_kind, page: params[:page].to_s,
                                            wanted: wanted_param, user: current_user)
    render json: { "leases" => leases.map(&:as_payload), "errors" => errors },
           status: errors.empty? ? :ok : :unprocessable_content
  end

  def release
    StreamLease.release(kind: lease_kind, page: params[:page].to_s)
    head :no_content
  end

  private
    def wanted_param
      list = params[:wanted]
      return [] if list.blank?
      Array(list).map do |w|
        w = w.respond_to?(:permit) ? w.permit(:target, fields: []).to_h : w.to_h
        { "target" => w["target"].to_s, "fields" => Array(w["fields"]) }
      end
    end
end
