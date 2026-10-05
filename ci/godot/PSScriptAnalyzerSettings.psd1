@{
    Severity     = @('Error', 'Warning')
    ExcludeRules = @(
        # A CLI talks to the console on purpose.
        'PSAvoidUsingWriteHost',
        # Internal helpers, not cmdlets: no -WhatIf, and names read better as they are.
        'PSUseShouldProcessForStateChangingFunctions',
        'PSUseSingularNouns',
        # Script parameters are read inside the script's functions, which the rule cannot see.
        'PSReviewUnusedParameter'
    )
}
