untyped

// ================================================================================================
//  JIXIE'S A-BRAWL MOD  —  mp_weapon_deployable_cover.nut
//  Step 1: Handheld amped shield that is carried in front of the player.
//
//  HOW IT WORKS (big picture):
//    • When the player activates the A-Wall offhand, instead of throwing anything we
//      immediately spawn an amped-wall prop and pin it in front of them every frame.
//    • The shield blocks damage from the forward hemisphere (any hit whose incoming
//      direction has a positive dot product with the player's facing vector).
//    • OnWeaponAttemptOffhandSwitch returns true so the animation plays and we can
//      hook into it; the actual "throw" is intercepted and replaced with shield logic.
//    • The shield is destroyed when the player: re-presses the ability, dies, or it
//      runs out of HP.
// ================================================================================================

global function MpWeaponDeployableCover_Init

global function OnWeaponTossPrep_weapon_deployable_cover
global function OnWeaponTossReleaseAnimEvent_weapon_deployable_cover
global function OnWeaponAttemptOffhandSwitch_weapon_deployable_cover

#if SERVER
global function CreateHeldAmpedWall
global function DestroyHeldAmpedWall
global function OnAmpedWallDamaged
global function GetAmpedWallsActiveCountForPlayer
global function HeldShield_ShouldBlockDamage
#endif

// ── Asset names ────────────────────────────────────────────────────────────────
const DEPLOYABLE_SHIELD_FX       = $"P_pilot_cover_shield"
const DEPLOYABLE_SHIELD_FX_AMPED = $"P_pilot_amped_shield"
const DEPLOYABLE_SHIELD_MODEL    = $"models/fx/pilot_shield_wall_amped.mdl"

// ── Fallback constants (overridden by ConVars at runtime) ──────────────────────
const int   DEPLOYABLE_SHIELD_HEALTH    = 850
const float SHIELD_FORWARD_OFFSET       = 40.0  // units in front of player origin
const float SHIELD_VERTICAL_OFFSET      = 0.0   // vertical tweak
const float DEPLOYABLE_SHIELD_DURATION  = 10.0  // seconds 

// ── File-scope state ───────────────────────────────────────────────────────────
struct
{
    // Tracks the active shield entity per player so we can destroy it cleanly.
    table< entity, entity > playerShieldTable

    int ampedFXIndex
} file


// ================================================================================================
//  INIT
// ================================================================================================
function MpWeaponDeployableCover_Init()
{
    PrecacheParticleSystem( DEPLOYABLE_SHIELD_FX )
    file.ampedFXIndex = PrecacheParticleSystem( DEPLOYABLE_SHIELD_FX_AMPED )
    PrecacheModel( DEPLOYABLE_SHIELD_MODEL )
}


// ================================================================================================
//  OFFHAND SWITCH GATE
//  Called every time the game considers letting the player bring up the offhand.
//  Return true  → allow the switch (plays deploy animation, leads to TossRelease).
//  Return false → block it (e.g. while shield is already active so second-press destroys).
// ================================================================================================
bool function OnWeaponAttemptOffhandSwitch_weapon_deployable_cover( entity weapon )
{
    #if SERVER
    entity player = weapon.GetWeaponOwner()
    if ( !IsValid( player ) )
        return false

    // If a shield is already active for this player, destroy it and block the switch
    // so we don't start a fresh deploy animation.
    if ( player in file.playerShieldTable )
    {
        entity existing = file.playerShieldTable[ player ]
        if ( IsValid( existing ) )
        {
            DestroyHeldAmpedWall( player )
            return false  // eat the press; shield is now gone
        }
        // Stale entry – clean it up and let a new shield spawn.
        delete file.playerShieldTable[ player ]
    }
    #endif

    return true
}


// ================================================================================================
//  TOSS PREP
//  Fires when the deploy animation starts.  We use it to play the deploy sound.
// ================================================================================================
void function OnWeaponTossPrep_weapon_deployable_cover( entity weapon, WeaponTossPrepParams prepParams )
{
    // Optional: play a sound here so the activation feels snappy.
    // weapon.EmitWeaponSound_1p3p( "Hardcover_Shield_Start_3P", "Hardcover_Shield_Start_3P" )
}


// ================================================================================================
//  TOSS RELEASE ANIM EVENT
//  Fires at the key frame of the deploy animation.
//  Instead of throwing a deployable, we spawn the held shield here.
// ================================================================================================
var function OnWeaponTossReleaseAnimEvent_weapon_deployable_cover( entity weapon, WeaponPrimaryAttackParams attackParams )
{
    #if SERVER
    entity owner = weapon.GetWeaponOwner()
    if ( IsValid( owner ) )
        CreateHeldAmpedWall( owner )
    #endif

    // Return 0 so no ammo is consumed (we manage ammo / cooldown manually).
    return 0
}


// ================================================================================================
//  CREATE HELD AMPED WALL  (SERVER ONLY)
// ================================================================================================
#if SERVER

void function CreateHeldAmpedWall( entity player )
{
    
    if ( !IsValid( player ) )
        return

    if ( player in file.playerShieldTable )
    {
        entity old = file.playerShieldTable[player]
        if ( IsValid( old ) )
            old.Destroy()
    }

    int health = GetConVarInt( "a_brawl_shield_health" )
    if ( health <= 0 )
        health = DEPLOYABLE_SHIELD_HEALTH

    float fwdOffset = GetConVarFloat( "a_brawl_shield_forward_offset" )
    float upOffset  = GetConVarFloat( "a_brawl_shield_vertical_offset" )
    float duration  = GetConVarFloat( "a_brawl_shield_duration" )

    entity wall = CreatePropDynamic(
        DEPLOYABLE_SHIELD_MODEL,
        player.GetOrigin(),
        player.EyeAngles(),
        SOLID_VPHYSICS
    )

    if ( !IsValid( wall ) )
    {
        print( "[A-Brawl] ERROR: Failed to spawn shield prop." )
        return
    }

    wall.kv.solid = 0
    wall.SetTakeDamageType( DAMAGE_YES )
    wall.SetDamageNotifications( true )
    wall.SetMaxHealth( 9999 )
    wall.SetHealth( 9999 )

    wall.SetPassThroughFlags( PTF_ADDS_MODS | PTF_NO_DMG_ON_PASS_THROUGH )
    wall.SetPassThroughThickness( 0 )
    wall.SetPassThroughDirection( -0.55 )

    StatusEffect_AddTimed( wall, eStatusEffect.pass_through_amps_weapon, 1.0, duration, 0.0 )

    wall.SetBlocksRadiusDamage( true )
    SetTeam( wall, TEAM_BOTH )

    AddEntityCallback_OnDamaged( wall, OnAmpedWallDamaged )

    wall.s.health <- health

    file.playerShieldTable[ player ] <- wall
    player.s.heldWall <- wall

    // Positioning thread
    thread HeldShield_PositionThread( wall, player, fwdOffset, upOffset )

    // FX
    PlayFXOnEntity( DEPLOYABLE_SHIELD_FX_AMPED, wall )
    EmitSoundOnEntity( wall, "Hardcover_Shield_Start_3P" )

    // Lifetime thread
    thread function() : (wall, player, duration)
    {
        wall.EndSignal("OnDestroy")
        player.EndSignal("OnDestroy")

        OnThreadEnd(
            function() : (wall, player)
            {
                if ( IsValid( wall ) )
                    wall.Destroy()

                if ( IsValid( player ) && "heldWall" in player.s )
                    player.s.heldWall = null
                    
                if ( player in file.playerShieldTable )
                    delete file.playerShieldTable[player]
            }
        )
        if ( duration > 0.0 )
            wait duration
        else
            wait -1
    }()
}

// ================================================================================================
//  POSITION THREAD — keeps the shield pinned in front of the player every frame
// ================================================================================================
void function HeldShield_PositionThread( entity wall, entity player, float fwdOffset, float upOffset )
{
    wall.EndSignal("OnDestroy")
    player.EndSignal("OnDestroy")

    while ( true )
    {
        vector eyeAngles = player.EyeAngles()
        vector forward   = AnglesToForward( eyeAngles )
        vector right     = AnglesToRight( eyeAngles )
        vector up        = AnglesToUp( eyeAngles )

        vector pos = player.GetOrigin()
                    + forward * fwdOffset
                    + up * upOffset
                    + right * -5  

        vector ang = <0, eyeAngles.y + 90, 0>

        wall.SetOrigin( pos )
        wall.SetAngles( ang )

        wait 0
    }
}


// ================================================================================================
//  DESTROY HELD AMPED WALL
// ================================================================================================
void function DestroyHeldAmpedWall( entity player )
{
    if ( !IsValid( player ) )
        return

    if ( !(player in file.playerShieldTable) )
        return

    entity wall = file.playerShieldTable[ player ]
    delete file.playerShieldTable[ player ]

    if ( IsValid( wall ) )
    {
        // Break effect.
        PlayFX( $"P_pilot_amped_shield_break", wall.GetOrigin(), wall.GetAngles() )
        EmitSoundAtPosition( TEAM_BOTH, wall.GetOrigin(), "Hardcover_Shield_End_3P" )
        wall.Destroy()
    }
}


// ================================================================================================
//  DAMAGE CALLBACK
// ================================================================================================
void function OnAmpedWallDamaged( entity wall, var damageInfo )
{
    // Only block / absorb damage that comes from the front hemisphere.
    if ( !HeldShield_ShouldBlockDamage( wall, damageInfo ) )
        return

    // Credit the attacker with a hit so killcam / hit markers work.
    entity attacker = DamageInfo_GetAttacker( damageInfo )
    if ( IsValid( attacker ) && attacker.IsPlayer() )
    {
        attacker.NotifyDidDamage(
            wall,
            0,
            DamageInfo_GetDamagePosition( damageInfo ),
            DamageInfo_GetCustomDamageType( damageInfo ),
            DamageInfo_GetDamage( damageInfo ),
            DamageInfo_GetDamageFlags( damageInfo ),
            DamageInfo_GetHitGroup( damageInfo ),
            DamageInfo_GetWeapon( damageInfo ),
            DamageInfo_GetDistFromAttackOrigin( damageInfo )
        )
    }

    // Apply the standard A-Wall damage scaling (amped walls reduce incoming damage).
    float damage = DamageInfo_GetDamage( damageInfo )
    ShieldDamageModifier mod = GetShieldDamageModifier( damageInfo )
    damage *= mod.damageScale
    DamageInfo_SetDamage( damageInfo, damage )

    // Drain our script-side health pool.
    wall.s.health -= damage

    // Destroy the shield when it runs out.
    if ( wall.s.health <= 0 )
    {
        entity owner = null
        foreach ( player, shield in file.playerShieldTable )
        {
            if ( shield == wall )
            {
                owner = player
                break
            }
        }

        if ( IsValid( owner ) )
            DestroyHeldAmpedWall( owner )
        else if ( IsValid( wall ) )
            wall.Destroy()
    }
}


// ================================================================================================
//  HEMISPHERE CHECK
//  Returns true if the incoming damage should be blocked by the shield.
//  The shield covers a full 180° in front of the player (dot product > 0).
// ================================================================================================
bool function HeldShield_ShouldBlockDamage( entity wall, var damageInfo )
{
    entity attacker = DamageInfo_GetAttacker( damageInfo )
    if ( !IsValid( attacker ) )
        return false

    // Find who owns this shield.
    entity owner = null
    foreach ( player, shield in file.playerShieldTable )
    {
        if ( shield == wall )
        {
            owner = player
            break
        }
    }

    if ( !IsValid( owner ) )
        return false

    // Player's current facing direction.
    vector playerForward = AnglesToForward( owner.EyeAngles() )

    // Direction from the attacker toward the player (i.e. the direction the shot is travelling).
    vector attackerToPlayer = Normalize( owner.GetOrigin() - attacker.GetOrigin() )

    // If dot > 0, the shot is coming from within the forward 180° arc → shield blocks it.
    return DotProduct( playerForward, attackerToPlayer ) > 0.0
}


// ================================================================================================
//  COMPATIBILITY STUB — called by other systems that track active amped walls
// ================================================================================================
int function GetAmpedWallsActiveCountForPlayer( entity player )
{
    if ( player in file.playerShieldTable )
    {
        entity wall = file.playerShieldTable[ player ]
        if ( IsValid( wall ) )
            return 1
    }
    return 0
}

#endif
