# Records a new console starts with (db:prepare runs this when it creates
# the database; idempotent: bin/rails db:seed again does nothing new).
#
# The role "match" (G1.5), an example to start from: playing a game of the
# app "game" against others. A console that was migrated from G0 gets the
# same role from its migration (with the rows that were "Player"). An
# admin may change or remove it, and it is not made again once any role
# exists. A "match" role without a description gets one (also done for
# existing consoles by db/migrate/*_relay_role_match_description.rb).
require Rails.root.join("db/migrate/20261014090000_relay_role_match_description").to_s
if RelayRole.none?
  RelayRole.create!(
    name: "match",
    description: RelayRoleMatchDescription.description("game"),
    rw_templates: "asterism/${node}\nasterism/${node}/game/**\nasterism/${node}/@profile",
    read_templates: "asterism/*\nasterism/*/game/**\nasterism/*/@profile",
    ask_templates: "asterism/*/@profile\nasterism/*/game/*/meta\nasterism/*/game/*/call/${node}",
    watch_templates: "asterism/**",
    for_browsers: true
  )
end
if (match = RelayRole.find_by(name: "match")) && match.description.blank?
  match.update!(description: RelayRoleMatchDescription.description(RelayRoleMatchDescription.app_of(match.rw_templates)))
end
