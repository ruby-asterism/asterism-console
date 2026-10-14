module RelayHelper
  # Whether the registry differs from the file the cloud router runs with
  # (the banner of the Registry and Roles pages).
  def relay_unapplied?
    return @relay_unapplied if defined?(@relay_unapplied)
    @relay_unapplied = !Relay::Applier.new.same_config?
  end

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

  # A time in the console's time zone (CONSOLE_TIME_ZONE), with the zone's
  # abbreviation (it is often shown alone).
  def when_text(t)
    t ? l(t.in_time_zone, format: "%Y-%m-%d %H:%M %Z") : "-"
  end

  # An ISO 8601 time (a file's, a status's) as when_text writes it.
  def iso_when(text)
    when_text(Time.iso8601(text.to_s))
  rescue ArgumentError
    text.to_s
  end
end
