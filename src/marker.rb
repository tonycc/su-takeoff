# src/marker.rb
module SuTakeoff
  class Marker
    MARKING_ATTR = 'su_takeoff_marking'

    # Apply marking to selected face
    # marking_data: { material_name:, part:, space:, waste_rate:, su_material_name: }
    def self.apply(marking_data)
      model = Sketchup.active_model
      model.selection.each do |entity|
        next unless entity.is_a?(Sketchup::Face)
        entity.set_attribute(MARKING_ATTR, 'data', JSON.generate(marking_data))
        # Tag face for visual feedback
        entity.set_attribute(MARKING_ATTR, 'applied_at', Time.now.to_i)
      end
    end

    # Remove marking from selected faces
    def self.clear_selected
      model = Sketchup.active_model
      model.selection.each do |entity|
        entity.delete_attribute(MARKING_ATTR) if entity.respond_to?(:delete_attribute)
      end
    end

    # Get all marked faces in the model
    def self.all_marked_faces
      marked = []
      model = Sketchup.active_model
      model.entities.each do |entity|
        next unless entity.is_a?(Sketchup::Face)
        raw = entity.get_attribute(MARKING_ATTR, 'data')
        next unless raw

        data = JSON.parse(raw)
        marked << { face: entity, data: data }
      end
      marked
    end

    # Build ScanItems from all marked faces (for inclusion in calculator)
    def self.to_scan_items
      items = []
      all_marked_faces.each do |entry|
        face = entry[:face]
        data = entry[:data]
        mat_name = data['su_material_name'] || data['material_name']
        items << ScanItem.new(
          face.entity_id,
          mat_name,
          face.area * 0.00064516,
          [face.normal.x, face.normal.y, face.normal.z],
          0, 0,
          face.layer.name,
          [data['space'] || '未分组']
        )
      end
      items
    end
  end
end
