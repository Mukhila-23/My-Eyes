def generate_scene_description(objects):

    if not objects:
        return "No objects detected."

    names = []

    for obj in objects:
        names.append(obj["object"])

    unique_objects = list(dict.fromkeys(names))

    if len(unique_objects) == 1:
        return f"There is a {unique_objects[0]} in front of you."

    if len(unique_objects) == 2:
        return (
            f"There is a {unique_objects[0]} "
            f"and a {unique_objects[1]} in front of you."
        )

    return (
        "I can see "
        + ", ".join(unique_objects[:-1])
        + " and "
        + unique_objects[-1]
        + " in front of you."
    )