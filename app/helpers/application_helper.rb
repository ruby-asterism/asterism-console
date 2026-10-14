module ApplicationHelper
  # A link of the menu (shared/_nav), marked as the current page when the
  # request's path is the link's (or under it, for a section such as the
  # relay pages): aria-current for screen readers, the class for the eye.
  def nav_link(label, path, under: nil)
    here = request.path
    current = under ? Array(under).any? { here == _1 || here.start_with?("#{_1}/") } : here == path
    link_to label, path, class: ("current" if current), aria: { current: ("page" if current) }
  end

  # The short name the menu shows for the signed-in user: the handle, or
  # the email address's local part when there is none yet (the whole
  # address is in the link's title).
  def nav_who(user)
    user.handle.presence || user.email_address.split("@").first
  end
end
