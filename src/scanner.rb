require 'set'

module SuTakeoff
  class Scanner
    def initialize
      @model = Sketchup.active_model
    end

    # Scan entire model or selected faces
    def scan(selection_only: false)
      items = []
      openings = []
      face_set = Set.new

      if selection_only && !@model.selection.empty?
        # Only scan selected faces
        @model.selection.each do |entity|
          collect_faces(entity, [], face_set, items, openings)
        end
      else
        # Scan entire model
        @model.entities.each do |entity|
          collect_faces(entity, [], face_set, items, openings)
        end
      end

      { items: items, openings: openings }
    end

    private

    def collect_faces(entity, path, face_set, items, openings)
      case entity
      when Sketchup::Face
        return if face_set.include?(entity.entity_id)
        face_set.add(entity.entity_id)

        # Skip hidden faces
        return if entity.hidden? || !entity.visible?

        # Read material
        mat_name = entity.material&.name

        # Check if this is an opening (transparent/glass-like material)
        if entity.material&.alpha && entity.material.alpha < 0.5
          openings << Opening.new(entity.entity_id, compute_area(entity), [])
          return
        end

        # Build component path names
        comp_path = path.map { |c| c.respond_to?(:name) ? c.name : c.to_s }

        # Get bounding box for width/height estimation
        bb = entity.bounds
        dims = [bb.width, bb.height, bb.depth].sort
        w = dims[-2] || 0
        h = dims[-1] || 0

        items << ScanItem.new(
          entity.entity_id,
          mat_name,
          compute_area(entity),
          [entity.normal.x, entity.normal.y, entity.normal.z],
          w.round(4),
          h.round(4),
          entity.layer.name,
          comp_path
        )

      when Sketchup::ComponentInstance
        # Recurse into component definition
        new_path = path + [entity]
        entity.definition.entities.each do |child|
          collect_faces(child, new_path, face_set, items, openings)
        end

        # Check if this component represents an opening (windows/doors)
        if entity.definition.name =~ /(window|door|窗|门)/i
          entity.definition.entities.each do |child|
            if child.is_a?(Sketchup::Face)
              openings << Opening.new(child.entity_id, compute_area(child), [])
            end
          end
        end

      when Sketchup::Group
        new_path = path + [entity]
        entity.entities.each do |child|
          collect_faces(child, new_path, face_set, items, openings)
        end

      when Sketchup::Image
        # Skip images
      end
    end

    def compute_area(face)
      area = face.area
      # Convert from inches to m (SU default unit is inches)
      area * 0.00064516
    end
  end
end
