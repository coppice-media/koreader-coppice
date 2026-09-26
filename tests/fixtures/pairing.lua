return {
    approved = {
        status = "approved",
        username = "fixture-user",
        device = { id = "fixture-device", name = "Fixture KOReader" },
        credentials = {
            { kind = "liseur_token", protocol = "liseur", secret = "fixture-liseur" },
            { kind = "api_key", protocol = "koreader", secret = "fixture-api" },
        },
    },
    denied = { status = "denied" },
    expired = { status = "expired" },
}
