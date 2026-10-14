# A small evaluator of zenohd's ACL rules, as far as the generated ACLs
# (Relay::CloudConfig) use them: asks an ACL one question (subject,
# message, flow, key). Subjects are certificate names, or :ws for the
# browsers' ws/ sessions.
module AclEvaluator
  module_function

  # zenohd's decision for one message: allowed when a rule of the subject's
  # policies lists the message and the flow and one of its key expressions
  # includes the key.
  def allowed?(acl, subject, message, flow, key)
    ids = acl["subjects"].select do |s|
      subject == :ws ? s["link_protocols"].to_a.include?("ws") : s["cert_common_names"].to_a.include?(subject)
    end.map { _1["id"] }
    rule_ids = acl["policies"].select { (_1["subjects"] & ids).any? }.flat_map { _1["rules"] }
    acl["rules"].any? do |r|
      rule_ids.include?(r["id"]) && r["messages"].include?(message) && r["flows"].include?(flow) &&
        r["key_exprs"].any? { includes?(_1, key) }
    end
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
