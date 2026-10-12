module RelayHelper
  def presence_badge(peer, seen)
    if seen.include?(peer.name)
      peer.enabled? ? tag.span("connected", class: "badge ok") : tag.span("connected, disabled", class: "badge warn")
    else
      tag.span("not here", class: "badge")
    end
  end

  def acl_badge(peer)
    return tag.span("in the ACL", class: "badge ok") if peer.in_acl?
    return tag.span("disabled", class: "badge bad") unless peer.enabled?
    tag.span("no valid certificate", class: "badge warn")
  end

  # The admin_space flag, by what it lets the console see: a router's
  # status passed through the cloud router (behind), or a client reading the
  # cloud router's status itself (reads). An entry in the cloud router's
  # ACL; the peer's own configuration does not change.
  def console_sees(peer, long: false)
    return long ? "no (the cloud router's ACL does not pass it)" : "-" unless peer.admin_space?
    if peer.kind == "router"
      long ? "behind it (the cloud router passes the console's status requests to it)" : "behind"
    else
      long ? "reads the cloud router's status" : "reads"
    end
  end

  def keys_list(text)
    lines = RelayPeer.lines(text)
    return tag.span("none", class: "hint") if lines.empty?
    safe_join(lines.map { tag.code(_1) }, tag.br)
  end

  def when_text(t)
    t ? l(t, format: "%Y-%m-%d %H:%M") : "-"
  end
end
