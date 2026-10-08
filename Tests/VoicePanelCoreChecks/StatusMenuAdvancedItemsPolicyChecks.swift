import VoicePanelCore

let statusMenuAdvancedItemsPolicyChecks: [CheckCase] = [
    CheckCase(name: "advanced status menu items stay hidden for a normal click") {
        try expect(
            !StatusMenuAdvancedItemsPolicy.shouldShow(optionModifierIsPressed: false),
            "advanced recovery and diagnostics actions should not clutter the normal status menu"
        )
    },
    CheckCase(name: "advanced status menu items appear while Option is held") {
        try expect(
            StatusMenuAdvancedItemsPolicy.shouldShow(optionModifierIsPressed: true),
            "holding Option while opening the status menu should reveal advanced actions"
        )
    },
]
