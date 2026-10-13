# A role of the relay registry (G1.5): a name and key templates. A row of
# the registry picks roles; the cloud router's ACL gives the row what its
# roles allow, with ${node} in a template expanded to each node the row
# speaks for (RelayPeer#node_list: the boards behind a home router, or the
# row's own name). The browsers (the ws/ subject) take the roles marked
# for_browsers, with ${node} expanded to the browsers' node pattern.
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
  # A Family-mruby-style app path or any page-relative app name; free text
  # within these characters (it travels in a URL fragment).
  APP = %r{\A[A-Za-z0-9_./-]{1,200}\z}

  has_many :peer_roles, class_name: "RelayPeerRole", dependent: :destroy
  has_many :peers, through: :peer_roles, source: :relay_peer

  validates :name, format: { with: NAME, message: "is lower case letters, digits, - and _" }, uniqueness: true
  validates :browser_app, format: { with: APP }, allow_blank: true
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

  # A template is a key expression once ${node} is put in; no other ${...}.
  def templates_are_keys
    templates.each do |section, lines|
      bad = lines.reject do |t|
        TEMPLATE.match?(t) && t.gsub(VARIABLE, "x").match?(RelayPeer::KEY) && !t.gsub(VARIABLE, "").include?("$" + "{")
      end
      errors.add(:"#{section}_templates", "has lines that are not key templates: #{bad.join(' ')}") if bad.any?
    end
  end
end
