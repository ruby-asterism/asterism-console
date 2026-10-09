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

  def keys_list(text)
    lines = RelayPeer.lines(text)
    return tag.span("none", class: "hint") if lines.empty?
    safe_join(lines.map { tag.code(_1) }, tag.br)
  end

  def when_text(t)
    t ? l(t, format: "%Y-%m-%d %H:%M") : "-"
  end
end
