Unit: format-fact (src: lib/gralkor/format.ex; unit: test/gralkor/format_test.exs)

when a fact is formatted
  then it renders as "- {fact}"
  where the fact carries timestamps
    then each present timestamp is appended in parentheses
    and the timestamps appear in the order created, valid from, invalid since, expired
    and absent timestamps contribute nothing to the rendering

when a timestamp is formatted
  then fractional seconds are stripped
  and a trailing "Z" becomes "+0"
  and a whole-hour zone offset drops zero-padding from its one- or two-digit hour
  and a zone offset with non-zero minutes is preserved as "+H:MM" or "-H:MM"
