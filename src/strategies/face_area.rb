module SuTakeoff
  module Strategies
    class FaceArea < Base
      def initialize(name: :face_area, match_rules: {})
        super(name: name, method: :area, default_unit: 'm²', match_rules: match_rules)
      end

      def aggregate(items, ctx)
        opening_map = ctx[:opening_area_by_face] || {}
        items.sum do |i|
          deduction = opening_map[i.face_occurrence_key]
          deduction = opening_map[i.face_id] if deduction.nil?
          deduction ||= 0.0
          [(i.qty_area || i.qty || 0).to_f - deduction, 0.0].max
        end
      end
    end
  end
end
