# frozen_string_literal: true

require_relative "errors"

module BaseCradle
  # Refuse to serialize an object that is a connection or a live query rather than a
  # record, and say what to serialize instead.
  #
  # With ActiveSupport loaded, +Object#as_json+ is +instance_values+ — every instance
  # variable, walked recursively. A Client's ivars include its raw +bc_uat_+ token, so
  # <tt>render json: { conn: bc }</tt> or <tt>logger.info({ conn: bc }.to_json)</tt> put
  # the credential in a response body or a log line, and **a token in a log is a token to
  # rotate**. That same walk reaches the client's eight collection ivars, and
  # ActiveSupport's +Enumerable#as_json+ calls +to_a+ — so serializing a client also fired
  # a live, unbounded, page-by-page GET loop before it got to the token, and serializing a
  # collection on its own fired one from inside the render for no stated reason.
  #
  # Without ActiveSupport the same calls were merely useless: +"#<BaseCradle::Client:0x…>"+,
  # a heap address that differs every run.
  #
  # +Marshal+ and Psych are that same act through two doors ActiveSupport never touched.
  # Both walk instance variables directly and neither consults +as_json+, so closing the
  # JSON door left them open, needing no ActiveSupport to be reachable. They are also the
  # worse pair, because they are what puts a credential *at rest*: ActiveSupport's cache
  # stores marshal what you write, so <tt>Rails.cache.write("bc", bc)</tt> landed the
  # token in Redis, memcached or a file; a Marshal-backed session landed it in the
  # session; Delayed::Job YAMLs its handler into the database. And nothing shadows the
  # ivar walk the way +Enumerable#as_json+ shadows +Object#as_json+ — so
  # <tt>Marshal.dump(bc.messages)</tt> reached the token where <tt>bc.messages.to_json</tt>
  # never did. Both doors now raise, on the same mixin, so every includer is covered.
  #
  # Includers supply +serialization_refusal+; the default below is the honest fallback
  # for one that does not, so the failure is still a rescuable BaseCradle::Error rather
  # than a NoMethodError out of a renderer.
  module NotSerializable
    # ActiveSupport's serialization hook — what reaches this object when it is nested in
    # something Rails renders (<tt>render json: { conn: bc }</tt>).
    def as_json(*)
      raise NotSerializableError, serialization_refusal
    end

    # +JSON.generate+, +Hash#to_json+, +Array#to_json+ and a bare
    # <tt>render json: bc</tt> all arrive here.
    def to_json(*)
      raise NotSerializableError, serialization_refusal
    end

    # +Marshal.dump+, and so every store built on it: ActiveSupport's cache backends, a
    # Marshal-backed session, and the <tt>Marshal.load(Marshal.dump(x))</tt> deep-copy
    # idiom. Marshal reaches for this hook before it walks ivars, so defining it is what
    # stops the walk.
    #
    # Deliberately unpaired with a +marshal_load+: the pair only matters to something
    # being loaded, and nothing can be loaded because nothing is ever dumped.
    def marshal_dump
      raise NotSerializableError, serialization_refusal
    end

    # Psych's hook — +to_yaml+, +YAML.dump+, and anything either one nests. Psych prefers
    # +encode_with+ over its own ivar walk for any object that defines it. The coder is
    # unused: it is the thing we decline to fill.
    def encode_with(_coder)
      raise NotSerializableError, serialization_refusal
    end

    private

    def serialization_refusal
      "#{self.class} is not a record and cannot be serialized."
    end
  end

  # What every lazy collection resource mixes in — the auto-paginating resources
  # (+bc.timelines+, +bc.messages+, +timeline.tasks+, any +.filter(...)+) and the
  # Paginator behind them.
  #
  # It includes +Enumerable+ itself, and that is load-bearing rather than tidy:
  # ActiveSupport defines +as_json+ and +to_json+ on +Enumerable+, so the refusal only
  # takes effect while it sits *ahead* of Enumerable in the ancestor chain. Pulling
  # Enumerable in here makes that true whichever order an including class writes its
  # +include+ lines — a module already in the chain is not moved by a later include — so
  # the guarantee is structural instead of a rule in a comment that a future resource can
  # forget. The classes still write +include Enumerable+ explicitly, because being
  # Enumerable is part of what they are.
  module NotSerializableCollection
    include Enumerable
    include NotSerializable

    private

    # One message, four doors — and it names both harms because which one you get depends
    # on the door, measured on this tree. Through JSON, ActiveSupport's
    # +Enumerable#as_json+ shadows +Object#as_json+, so a collection serialized as its
    # fetched records and the client in its ivars was never walked: the harm is the
    # unbounded fetch. +Marshal+ and Psych have no such shadow and walked the ivars
    # instead, reaching the token and writing it wherever the dump went.
    #
    # Naming only the fetch would have told a +Rails.cache.write+ caller their credential
    # was slow to write rather than at rest in Redis — a wrong diagnosis being worse than
    # a missing one. Naming both keeps one refusal per resource, which is what stops the
    # doors drifting apart.
    def serialization_refusal
      "#{self.class} is a lazy, auto-paginating query holding your connection, not a " \
      "record, so there is no one record to serialize. Serializing it either runs a " \
      "page-by-page GET loop over the whole resource from inside your renderer and " \
      "emits every record it fetched, or writes out the connection it holds — your " \
      "bc_uat_ token with it. Call .to_a (or .first(n), or .filter(...).to_a) and " \
      "serialize that — then how much you fetch is a visible act in your own code."
    end
  end
end
