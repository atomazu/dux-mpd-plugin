import QtQuick
import qs.Common
import qs.DCommon.Widgets as Material

// Dux supplies ripple, focus, disabled states, and expressive shape transitions.
Material.DButton {
    property bool prominent: false
    buttonHeight: Theme.buttonHeightXS
    backgroundColor: prominent ? Theme.primary : Theme.secondaryContainer
    textColor: prominent ? Theme.onPrimary : Theme.onSecondaryContainer
}
