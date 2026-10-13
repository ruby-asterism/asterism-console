# Records a new console starts with (db:prepare runs this when it creates
# the database; idempotent: bin/rails db:seed again does nothing new).
#
# The role "match" (G1.5), an example to start from: playing a game of the
# app "game" against others. A console that was migrated from G0 gets the
# same role from its migration (with the rows that were "Player"). An
# admin may change or remove it, and it is not made again once any role
# exists.
if RelayRole.none?
  RelayRole.create!(
    name: "match",
    description: "Play a game against others: write at your own nodes' game app, read every node's, " \
                 "call others only under your own name.",
    rw_templates: "asterism/${node}\nasterism/${node}/game/**\nasterism/${node}/@profile",
    read_templates: "asterism/*\nasterism/*/game/**\nasterism/*/@profile",
    ask_templates: "asterism/*/@profile\nasterism/*/game/*/meta\nasterism/*/game/*/call/${node}",
    watch_templates: "asterism/**",
    for_browsers: true
  )
end
