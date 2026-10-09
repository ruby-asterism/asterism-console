# What an open plot or log page wants from the bridge (V3). Like RateLease,
# the page renews its rows while it is open and the bridge subscribes only
# to what has a live row; a page that closes releases its rows at once
# (PlotsController#release), and one that just goes away is forgotten when
# its rows run out.
#
#   kind "plot": target a ROS 2 topic id ("r_topic:0/cmd_vel") or an
#                Asterism key expression ("key:demo/imu"), fields the paths
#                drawn from it (Bridge::Fields; none while the page only
#                looks at what the topic has).
#   kind "log":  target "*" (/rosout of every ROS 2 domain and the Asterism
#                log keys).
#
# page: a random token per open page, so one page's renewal replaces its
# own rows and not another page's. meta: what the bridge knows of the
# target (type, fields, error), written by the bridge.
class StreamLease < ApplicationRecord
  LIFETIME = 30.seconds
  KINDS = %w[plot log].freeze
  # How much one page may ask for.
  MAX_TARGETS = 8
  MAX_FIELDS = 16
  PAGE = /\A[A-Za-z0-9_-]{8,64}\z/
  # An Asterism (or any Zenoh) key expression: no blanks, no admin space.
  KEY = %r{\Akey:[^@\s][^\s]{0,199}\z}

  belongs_to :user, optional: true

  validates :kind, inclusion: { in: KINDS }
  validates :page, format: { with: PAGE }
  validate :target_fits_kind
  validate :fields_are_paths

  scope :live, -> { where(expires_at: Time.current..) }

  def self.target?(kind, target)
    case kind
    when "plot" then RateLease::TOPIC.match?(target.to_s) || KEY.match?(target.to_s)
    when "log" then target == "*"
    else false
    end
  end

  # Replaces what one page asks for: wanted is [{ "target" =>, "fields" => [...] }].
  # Returns [leases, errors].
  def self.renew_page(kind:, page:, wanted:, user: nil)
    wanted = Array(wanted).first(MAX_TARGETS)
    errors = []
    leases = []
    transaction do
      targets = wanted.map { _1["target"].to_s }
      where(kind: kind, page: page).where.not(target: targets).delete_all
      wanted.each do |w|
        lease = find_or_initialize_by(kind: kind, page: page.to_s, target: w["target"].to_s)
        lease.fields_list = Array(w["fields"]).map(&:to_s).uniq
        lease.user = user
        lease.expires_at = LIFETIME.from_now
        if lease.save
          leases << lease
        else
          errors << "#{w['target'].to_s[0, 80]}: #{lease.errors.full_messages.join(', ')}"
        end
      end
    end
    [ leases, errors ]
  rescue ActiveRecord::RecordNotUnique
    retry # the same page renewed twice at once
  end

  def self.release(kind:, page:)
    where(kind: kind, page: page.to_s).delete_all
  end

  # The live targets of a kind with the fields every page wants of each
  # ({ target => [paths] }), the expired rows removed.
  def self.wanted(kind)
    where(expires_at: ...Time.current).delete_all
    live.where(kind: kind).order(:id).pluck(:target, :fields).each_with_object({}) do |(target, fields), out|
      (out[target] ||= []).concat(fields.present? ? JSON.parse(fields) : []).uniq!
    end
  end

  # The bridge tells every page that plots target what it knows of it.
  def self.write_meta(kind, target, meta)
    json = JSON.generate(meta)
    where(kind: kind, target: target).where("meta IS NULL OR meta != ?", json).update_all(meta: json)
  end

  def fields_list
    fields.present? ? JSON.parse(fields) : []
  end

  def fields_list=(list)
    self.fields = JSON.generate(list)
  end

  def meta_value
    meta.present? ? JSON.parse(meta) : nil
  end

  def as_payload
    { "target" => target, "fields" => fields_list, "meta" => meta_value, "expires_at" => expires_at }
  end

  private
    def target_fits_kind
      errors.add(:target, "is not a topic id or key:<key expression>") unless self.class.target?(kind, target)
    end

    def fields_are_paths
      list = fields_list
      errors.add(:fields, "are more than #{MAX_FIELDS}") if list.size > MAX_FIELDS
      bad = list.reject { Bridge::Fields.valid?(_1) }
      errors.add(:fields, "are not paths: #{bad.first(3).join(', ')}") if bad.any?
      errors.add(:fields, "are for plots only") if kind == "log" && list.any?
    rescue JSON::ParserError
      errors.add(:fields, "are not a list")
    end
end
