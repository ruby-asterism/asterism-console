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

  # The backups' warning for admins (lib/console_backup.rb): the last daily
  # backup failed, or none for two days. nil when all is well or no backup
  # ever ran here.
  def backup_warning
    ConsoleBackup::Status.warning(ConsoleBackup.dir(Rails.root.to_s),
                                  format: ->(t) { t.in_time_zone.strftime("%Y-%m-%d %H:%M %Z") })
  end

  # The last good backup's name and time, for the Users page.
  def backup_status
    ConsoleBackup::Status.read(ConsoleBackup.dir(Rails.root.to_s))
  end
end
