# frozen_string_literal: true

module ::CgsfVouch
  class Engine < ::Rails::Engine
    engine_name "cgsf_vouch"
    isolate_namespace CgsfVouch
  end
end
