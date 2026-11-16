# frozen_string_literal: true

module BaseCradle
  # What stops HTTP carrying +value+ exactly as given, or +nil+ when nothing does. It is the
  # one rule for a value the SDK sends in a header as the caller gave it, never stripped or
  # repaired: an idempotency key (#295) and the bearer token (#301) alike. The rule lives
  # here, below the client and the resources, so both can ask it.
  #
  # The value must be printable ASCII (+!+ to +~+), with spaces or tabs allowed only between
  # those characters. Net::HTTP refuses only CR and LF. It sends NUL, every other control
  # character and non-ASCII bytes. A hop that receives whitespace at either end of a value
  # strips it, so the platform would read a different value. The rule every SDK shares
  # refuses all of them, not whatever one HTTP library tolerates. A string in an encoding
  # that is not ASCII-compatible (UTF-16, say) is refused as a whole: its bytes are not the
  # characters it holds.
  #
  # The answer is <tt>[index, reason]</tt>: the index of the character at fault, or +nil+
  # where no one character is (whitespace at either end, an encoding). The character itself
  # is never part of the answer, so a caller describing the token can say where the fault
  # is without showing any of it.
  def self.header_value_defect(value)
    unless value.encoding.ascii_compatible?
      return [ nil, "its encoding, #{value.encoding}, is not ASCII-compatible; pass an ASCII or UTF-8 string" ]
    end

    value.each_char.with_index do |char, index|
      # ascii_only? first: an invalid byte is not ASCII, and +ord+ would raise on it.
      return [ index, "is not ASCII" ] unless char.ascii_only?
      return [ index, "is a control character" ] unless char == " " || char == "\t" || (0x21..0x7E).cover?(char.ord)
    end
    return unless value.start_with?(" ", "\t") || value.end_with?(" ", "\t")

    [ nil, "it begins or ends with whitespace, which a header value cannot" ]
  end
end
