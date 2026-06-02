module SuTakeoff
  module Strategies
    class FaceArea < Base
      def initialize
        super(name: :face_area, method: :area, default_unit: 'm²')
      end

      def aggregate(items, ctx)
        opening_map = ctx[:opening_area_by_face] || {}
        items.sum do |i|
          deduction = opening_map[i.face_id] || 0.0
          [i.qty - deduction, 0.0].max
        end
      end
    end
  end
end
