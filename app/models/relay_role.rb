# A role of the relay registry (G1.5): a name and key templates. A row of
# the registry picks roles; the cloud router's ACL gives the row what its
# roles allow, with ${node} in a template expanded to each node the row
# speaks for (RelayPeer#node_list: the boards behind a home router, or the
# row's own name). The browsers (the ws/ subject) take the roles marked
# for_browsers, with ${node} expanded to the browsers' node pattern; a
# user's own browser (the page with the user's certificate) also takes the
# roles picked for that user (RelayUserRole, 0.4.2), never the shared ws/
# subject. A role
# is permissions only: the apps a browser page starts are a list of their
# own (BrowserApp, 0.3.12; each role had one before).
#
# Four lists, one per kind of access (Relay::CloudConfig::SECTIONS):
#   rw     every message, both directions: the role's own place
#   read   subscribe and liveliness queries from it, everything towards it
#   ask    queries from it (an Asterism call or meta is a query): e.g. calls
#          only under its own name, asterism/*/<app>/*/call/${node}
#   watch  the liveliness watch from it (asterism/**: the asterism gem
#          declares that one; what reaches it is cut by the other rules)
class RelayRole < ApplicationRecord
  NAME = /\A[a-z0-9][a-z0-9_-]{0,40}\z/
  # A key template: a key expression, where ${node} stands for one chunk.
  TEMPLATE = %r{\A[A-Za-z0-9_\-.*@~%:+=/${}]{1,200}\z}
  VARIABLE = "${node}".freeze
  # Zenoh's wildcard inside a chunk (room$*: room01, room02, ...), passed to
  # the router as it is.
  SUB_CHUNK = "$*".freeze

  has_many :peer_roles, class_name: "RelayPeerRole", dependent: :destroy
  has_many :peers, through: :peer_roles, source: :relay_peer
  # Users whose own browser has this role (0.4.2; the page with the user's
  # certificate only).
  has_many :user_roles, class_name: "RelayUserRole", dependent: :destroy
  has_many :users, through: :user_roles

  validates :name, format: { with: NAME, message: "is lower case letters, digits, - and _" }, uniqueness: true
  validate :templates_are_keys

  def self.lines(text)
    RelayPeer.lines(text)
  end

  def templates
    Relay::CloudConfig::SECTIONS.to_h { [ _1, self.class.lines(self["#{_1}_templates"]) ] }
  end

  def empty_templates?
    templates.values.all?(&:empty?)
  end

  # What Relay::CloudConfig takes.
  def to_config
    { "name" => name, "templates" => templates, "for_browsers" => for_browsers? }
  end

  private

  # A template is a key expression once ${node} is put in; no other ${...};
  # $* inside a chunk is Zenoh's.
  def templates_are_keys
    templates.each do |section, lines|
      bad = lines.reject do |t|
        TEMPLATE.match?(t) && t.gsub(VARIABLE, "x").gsub(SUB_CHUNK, "x").match?(RelayPeer::KEY) &&
          !t.gsub(VARIABLE, "").include?("$" + "{")
      end
      errors.add(:"#{section}_templates", "has lines that are not key templates: #{bad.join(' ')}") if bad.any?
    end
  end
end
