extends VBoxContainer

func setup(ship):
    $Info.text = ship.name + "\nHP: " + str(ship.hp) + "\nKalkan: " + str(ship.shield) + "\nHız: " + str(ship.speed) + "\nFiyat: " + str(ship.price)
    var tex=load(ship.image)
    $Image.texture=tex