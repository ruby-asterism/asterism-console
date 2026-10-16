# A small evaluator of zenohd's ACL rules, as far as the generated ACLs
# (Relay::CloudConfig) use them: asks an ACL one question (subject,
# message, flow, key). Subjects are certificate names, or :ws for the
# browsers' ws/ sessions; a certificate's session is on a tls link unless
# link: says otherwise.
#
# As zenohd 1.10.1 decides (zenoh/src/net/routing/interceptor/
# authorization.rs, access_control.rs): a session is every subject whose
# fields all match it (the common name, the link protocol); inside one
# subject a deny rule that includes the key wins over its allow rules; of
# the subjects, any one that allows lets the message through.
module AclEvaluator
  module_function

  def allowed?(acl, subject, message, flow, key, link: subject == :ws ? "ws" : "tls")
    subjects = acl["subjects"].select { matches?(_1, subject, link) }
    subjects.any? do |s|
      rule_ids = acl["policies"].select { _1["subjects"].include?(s["id"]) }.flat_map { _1["rules"] }
      rules = acl["rules"].select do |r|
        rule_ids.include?(r["id"]) && r["messages"].include?(message) && r["flows"].include?(flow) &&
          r["key_exprs"].any? { includes?(_1, key) }
      end
      rules.none? { _1["permission"] == "deny" } && rules.any? { _1["permission"] == "allow" }
    end
  end

  def matches?(s, subject, link)
    names = s["cert_common_names"]
    links = s["link_protocols"]
    return false if names.nil? && links.nil?
    return false if names && (subject == :ws || !names.include?(subject))
    links.nil? || links.include?(link)
  end

  # Does key expression a include b (every key b matches, a matches)?
  # Chunks: ** (any number), * (one), and $* inside a chunk.
  def includes?(a, b)
    chunks_include?(a.split("/"), b.split("/"))
  end

  def chunks_include?(a, b)
    return b.empty? if a.empty?
    if a.first == "**"
      return true if chunks_include?(a.drop(1), b)
      return false if b.empty? || b.first.start_with?("@")
      return chunks_include?(a, b.drop(1))
    end
    return false if b.empty? || b.first == "**"
    chunk_include?(a.first, b.first) && chunks_include?(a.drop(1), b.drop(1))
  end

  def chunk_include?(a, b)
    return !b.start_with?("@") if a == "*"
    return false if b == "*"
    return a == b unless a.include?("$*")
    Regexp.new("\\A" + a.split("$*", -1).map { Regexp.escape(_1) }.join("[^/]*") + "\\z").match?(b)
  end
end
