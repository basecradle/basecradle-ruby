# frozen_string_literal: true

module BaseCradle
  # Print what an object *is*, never what it holds.
  #
  # Every renderable object in this SDK follows one rule — a render shows field names and
  # never field values — and the rule is what keeps secrets out of logs, REPL transcripts,
  # exception messages and +p+ calls. It is load-bearing in three separate places:
  # +Client+ holds a live +bc_uat_+ token; a +WebhookEventHeaders+ holds whatever an
  # inbound sender put in its headers, which is another party's credential; and an
  # +ApiObject+ holds a record's values, including an endpoint's +ingest_url+.
  #
  # The rule used to exist as three hand-rolled copies of the same three methods, with no
  # fourth class ever being asked the question. That is exactly how the leak in 0.10.2
  # arrived: +WebhookEventHeaders+ was added as a +Hash+ descendant, +Hash+ brought its
  # own render, and every value printed with the suite green. Here it is one module, so a
  # class added later either includes it or fails the reflective guard in
  # +test/basecradle/rendering_test.rb+.
  #
  # Three doors, because a render arrives through three:
  #
  # - +inspect+ — +p+, a REPL echo, an exception's backtrace context, a nested +inspect+.
  # - +to_s+ — string interpolation and +puts+, which is the door people reach for without
  #   thinking about it. +Hash+ aliases +to_s+ to its *own* +inspect+ as one shared method
  #   entry, so overriding +inspect+ alone leaves <tt>"#{headers}"</tt> printing values.
  # - +pretty_print+ — +pp+. +pp+ uses an object's own +inspect+ when it defines one, which
  #   is why an +ApiObject+ was already safe here and only a +Hash+ descendant was not;
  #   delegating makes that a property of the module rather than a coincidence of which
  #   superclass a class happens to have.
  #
  # +to_s+ is late-bound to +inspect+ rather than written <tt>alias to_s inspect</tt>: an
  # alias copies the method body at alias time, so a subclass that redacts more in
  # +inspect+ would be bypassed by interpolation.
  module RendersNamesOnly
    def inspect
      body = render_body
      body.nil? ? "#<#{self.class}>" : "#<#{self.class} #{body}>"
    end

    def to_s
      inspect
    end

    def pretty_print(printer)
      printer.text(inspect)
    end

    private

    # What goes inside the angle brackets after the class name — names, never values.
    # Includers supply it.
    #
    # +nil+ means "there is nothing to show" and renders the bare <tt>#<Class></tt>;
    # anything else is rendered after a space, the empty string included. That
    # distinction is not pedantry: a webhook delivery carrying one header whose *name* is
    # the empty string is not the same delivery as one carrying no headers, and folding
    # the two would report a header that arrived as a header that did not. So emptiness
    # is the includer's question about its own contents, never this module's question
    # about the string it was handed.
    #
    # The default raises rather than returning something bland, because a silent fallback
    # would render an object as its class name alone and look deliberate; this SDK would
    # rather fail in the test that includes the module.
    def render_body
      raise NotImplementedError,
            "#{self.class} includes BaseCradle::RendersNamesOnly but defines no " \
            "#render_body, so there is nothing for #inspect to print. Supply one " \
            "returning field names — never field values."
    end
  end
end
