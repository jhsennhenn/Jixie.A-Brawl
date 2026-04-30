untyped

// ======================================================================================================
//  JIXIE'S A-BRAWL MOD
//  Changes the A-Wall ability from a deployable cover to a personal shield that stays with the player.
// ======================================================================================================

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
global function CreateScaledDome
#endif

const DOME_SHIELD_MODEL = $"models/fx/xo_shield.mdl"
const asset DOME_FX_NAME = $"awall_dome_fx"

const SHIELD_BREAK_FX  = $"P_pilot_amped_shield_break"
const SHIELD_START_SFX = "Hardcover_Shield_Start_3P"
const SHIELD_END_SFX   = "Hardcover_Shield_End_3P"
const SHIELD_HIT_SFX   = "Hardcover_Shield_Hit_3P"

const int   DEFAULT_SHIELD_HEALTH  = 850
const float DEFAULT_FORWARD_OFFSET = 50.0
const float DEFAULT_VERTICAL_OFFSET = 0.0
const float DEFAULT_DOME_SCALE     = 0.35
const vector SHIELD_COLOR          = < 1.0, 0.45, 0.0 >

struct
{
    table< entity, entity >        playerShieldTable
    table< entity, entity >        playerWeaponTable  // player → weapon, for timer cancel and sounds
    table< entity, array<entity> > wallFXTable
    int bubbleFXIndex
    bool initHasBeenCalledOnce = false
} file

void function EnsureShieldFXPrecached()
{
    #if SERVER
    if ( file.initHasBeenCalledOnce )
        return

    PrecacheModel( DOME_SHIELD_MODEL )
    file.bubbleFXIndex = PrecacheParticleSystem( DOME_FX_NAME )

    if ( file.bubbleFXIndex == 0 )
        print( "[A-Brawl] WARNING: FX not found: " + DOME_FX_NAME )
    else
        print( "[A-Brawl] bubbleFXIndex = " + string( file.bubbleFXIndex ) )

    file.initHasBeenCalledOnce = true
    #endif
}

function MpWeaponDeployableCover_Init()
{
}

// ================================================================================================
//  OFFHAND SWITCH GATE
// ================================================================================================
bool function OnWeaponAttemptOffhandSwitch_weapon_deployable_cover( entity weapon )
{
    #if SERVER
    entity player = weapon.GetWeaponOwner()
    if ( !IsValid( player ) )
        return false

    if ( player in file.playerShieldTable )
    {
        entity existing = file.playerShieldTable[ player ]
        if ( IsValid( existing ) )
        {
            float dashSpeed = GetConVarFloat( "a_brawl_dash_speed" )
            if ( dashSpeed > 0.0 )
                ABrawl_DashForward( player, dashSpeed )

            DestroyHeldAmpedWall( player )
            return false
        }
        delete file.playerShieldTable[ player ]
    }
    #endif

    return true
}

// ================================================================================================
//  TOSS PREP
// ================================================================================================
void function OnWeaponTossPrep_weapon_deployable_cover( entity weapon, WeaponTossPrepParams prepParams )
{
    weapon.EmitWeaponSound_1p3p( GetGrenadeDeploySound_1p( weapon ), GetGrenadeDeploySound_3p( weapon ) )
}

// ================================================================================================
//  TOSS RELEASE
// ================================================================================================
var function OnWeaponTossReleaseAnimEvent_weapon_deployable_cover( entity weapon, WeaponPrimaryAttackParams attackParams )
{
    weapon.EmitWeaponSound_1p3p( GetGrenadeThrowSound_1p( weapon ), GetGrenadeThrowSound_3p( weapon ) )

    #if SERVER
    entity owner = weapon.GetWeaponOwner()
    if ( IsValid( owner ) )
    {
        CreateHeldAmpedWall( owner, weapon )
        // Tell the engine the offhand was used — starts clip regen = cooldown arc
        PlayerUsedOffhand( owner, weapon )
    }
    #endif

    // Return ammo cost so the engine drains the clip
    return weapon.GetAmmoPerShot()
}

#if SERVER

/*
    This works if you remove the cooldown timer logic. Of course,
    this breaks the cooldown timer, but you can do a dash like this 
    and also cancel your shield at will.
*/
void function ABrawl_DashForward( entity player, float dashSpeed )
{
    vector forward    = AnglesToForward( player.EyeAngles() )
    vector currentVel = player.GetVelocity()
    player.SetVelocity( currentVel + forward * dashSpeed )
}

entity function CreateScaledDome( entity owner, float domeScale, vector domeColor )
{
    entity dome = CreateEntity( "prop_dynamic" )
    dome.SetValueForModelKey( DOME_SHIELD_MODEL )

    dome.kv.solid          = 0
    dome.kv.CollisionGroup = TRACE_COLLISION_GROUP_NONE
    dome.kv.rendercolor    = format( "%d %d %d",
        int( domeColor.x * 255 ),
        int( domeColor.y * 255 ),
        int( domeColor.z * 255 )
    )
    dome.kv.modelscale = domeScale.tostring()
    dome.kv.renderamt  = 255
    dome.kv.renderfx   = 0
    // rendermode intentionally NOT set

    dome.SetOrigin( owner.GetOrigin() )
    dome.SetAngles( owner.GetAngles() )

    DispatchSpawn( dome )

    dome.SetParent( owner )
    dome.SetLocalOrigin( < 0, 0, 0 > )
    dome.SetLocalAngles( < 0, 0, 0 > )

    return dome
}

// ================================================================================================
//  CREATE HELD AMPED WALL
// ================================================================================================
void function CreateHeldAmpedWall( entity player, entity weapon )
{
    if ( !IsValid( player ) || !IsAlive( player ) )
        return

    EnsureShieldFXPrecached()

    if ( player in file.playerShieldTable )
    {
        entity old = file.playerShieldTable[ player ]
        if ( IsValid( old ) )
            DestroyHeldAmpedWall( player )
    }

    float fwdOffset  = GetConVarFloat( "a_brawl_shield_forward_offset" )
    float upOffset   = GetConVarFloat( "a_brawl_shield_vertical_offset" )
    float duration   = GetConVarFloat( "a_brawl_shield_duration" )
    float domeScale  = GetConVarFloat( "a_brawl_dome_scale" )
    float domeHealth = GetConVarFloat( "a_brawl_shield_health" )
    bool  domeHide   = GetConVarBool( "a_brawl_shield_hide" )

    if ( domeHealth <= 0 ) domeHealth = DEFAULT_SHIELD_HEALTH
    if ( domeScale <= 0.0 ) domeScale = DEFAULT_DOME_SCALE

    entity wall = CreateEntity( "prop_dynamic" )
    wall.SetValueForModelKey( DOME_SHIELD_MODEL )
    wall.kv.modelscale     = domeScale.tostring()
    wall.kv.solid          = SOLID_VPHYSICS
    wall.kv.CollisionGroup = TRACE_COLLISION_GROUP_BLOCK_WEAPONS_AND_PHYSICS
    wall.SetOrigin( player.GetOrigin() )
    wall.SetAngles( < 90, player.EyeAngles().y, 0 > )
    DispatchSpawn( wall )

    if ( domeHide ) wall.Hide()

    CreateScaledDome( wall, domeScale, SHIELD_COLOR )

    wall.SetTakeDamageType( DAMAGE_YES )
    wall.SetDamageNotifications( true )
    wall.SetMaxHealth( domeHealth )
    wall.SetHealth( domeHealth )
    wall.SetPassThroughFlags( PTF_ADDS_MODS | PTF_NO_DMG_ON_PASS_THROUGH )
    wall.SetPassThroughThickness( 0 )
    wall.SetPassThroughDirection( -0.55 )
    wall.SetBlocksRadiusDamage( true )
    wall.kv.contents = ( int( wall.kv.contents ) | CONTENTS_NOGRAPPLE )

    if ( duration > 0.0 )
        StatusEffect_AddTimed( wall, eStatusEffect.pass_through_amps_weapon, 1.0, duration, 0.0 )
    else
        StatusEffect_AddTimed( wall, eStatusEffect.pass_through_amps_weapon, 1.0, 1, 0.0 )

    SetTeam( wall, TEAM_BOTH )
    wall.s.domeHealth <- domeHealth

    AddEntityCallback_OnDamaged( wall, OnAmpedWallDamaged )

    file.playerShieldTable[ player ] <- wall
    file.playerWeaponTable[ player ] <- weapon
    file.wallFXTable[ wall ] <- []

    // ── HUD active timer ──────────────────────────────────────────────────────
    //  Drives the ability arc on the HUD while the shield is active.
    //  Cleared early in DestroyHeldAmpedWall via StatusEffect_Remove.
    if ( duration > 0.0 )
        StatusEffect_AddTimed( weapon, eStatusEffect.simple_timer, 1.0, duration, duration )

    // ── Sustain sound on player ───────────────────────────────────────────────
    //  Must be on player (always networked), not wall.
    //  Stopped explicitly in DestroyHeldAmpedWall.
    EmitSoundOnEntity( player, SHIELD_START_SFX )

    thread HeldShield_LifetimeThread( wall, player, duration )
    thread HeldShield_PositionThread( wall, player, fwdOffset, upOffset )
}

// ================================================================================================
//  POSITION THREAD
// ================================================================================================
void function HeldShield_PositionThread( entity wall, entity player, float fwdOffset, float upOffset )
{
    wall.EndSignal( "OnDestroy" )
    player.EndSignal( "OnDestroy" )

    while ( IsValid( wall ) && IsValid( player ) && IsAlive( player ) )
    {
        vector eyeAngles    = player.EyeAngles()
        vector forward      = AnglesToForward( eyeAngles )
        vector worldUp      = < 0, 0, 1 >

        vector shieldOrigin = player.GetOrigin()
                            + forward  * fwdOffset
                            + worldUp  * upOffset
        vector shieldAngles = eyeAngles + < 90, 0, 0 >

        wall.SetOrigin( shieldOrigin )
        wall.SetAngles( shieldAngles )

        WaitFrame()
    }
}

// ================================================================================================
//  LIFETIME THREAD
// ================================================================================================
void function HeldShield_LifetimeThread( entity wall, entity player, float duration )
{
    if ( !IsValid( wall ) || !IsValid( player ) )
        return

    wall.EndSignal( "OnDestroy" )
    player.EndSignal( "OnDestroy" )

    OnThreadEnd(
        function() : ( player )
        {
            if ( IsValid( player ) )
                DestroyHeldAmpedWall( player )
        }
    )

    if ( duration <= 0.0 )
        duration = 99999.0

    wait duration
}

// ================================================================================================
//  DESTROY HELD AMPED WALL
// ================================================================================================
void function DestroyHeldAmpedWall( entity player )
{
    if ( !IsValid( player ) )
        return

    if ( !( player in file.playerShieldTable ) )
        return

    entity wall = file.playerShieldTable[ player ]
    delete file.playerShieldTable[ player ]

    // ── Weapon cleanup ────────────────────────────────────────────────────────
    entity weapon = null
    if ( player in file.playerWeaponTable )
    {
        weapon = file.playerWeaponTable[ player ]
        delete file.playerWeaponTable[ player ]
    }

    if ( IsValid( weapon ) )
    {
        weapon.SetWeaponPrimaryClipCount( 0 )
    }

    StopSoundOnEntity( player, SHIELD_START_SFX )
    EmitSoundOnEntity( player, SHIELD_END_SFX )

    if ( IsValid( wall ) )
    {
        if ( wall in file.wallFXTable )
        {
            array<entity> fxList = file.wallFXTable[ wall ]
            delete file.wallFXTable[ wall ]
            foreach ( fx in fxList )
            {
                if ( IsValid( fx ) )
                    EffectStop( fx )
            }
        }

        PlayFX( SHIELD_BREAK_FX, wall.GetOrigin(), wall.GetAngles() )

        wall.Destroy()
        // Dome parented to wall — auto-destroyed here
    }
}

// ================================================================================================
//  DAMAGE CALLBACK
// ================================================================================================
void function OnAmpedWallDamaged( entity wall, var damageInfo )
{
    if ( !HeldShield_ShouldBlockDamage( wall, damageInfo ) )
        return

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

    EmitSoundOnEntity( wall, SHIELD_HIT_SFX )

    float damage = DamageInfo_GetDamage( damageInfo )
    ShieldDamageModifier mod = GetShieldDamageModifier( damageInfo )
    damage *= mod.damageScale
    DamageInfo_SetDamage( damageInfo, damage )

    wall.s.domeHealth -= damage

    if ( wall.s.domeHealth <= 0 )
    {
        entity owner = null
        foreach ( player, shield in file.playerShieldTable )
        {
            if ( shield == wall ) { owner = player; break }
        }

        if ( IsValid( owner ) )
            DestroyHeldAmpedWall( owner )
        else if ( IsValid( wall ) )
            wall.Destroy()
    }
}

// ================================================================================================
//  HEMISPHERE CHECK
// ================================================================================================
bool function HeldShield_ShouldBlockDamage( entity wall, var damageInfo )
{
    entity attacker = DamageInfo_GetAttacker( damageInfo )
    if ( !IsValid( attacker ) )
        return false

    entity owner = null
    foreach ( player, shield in file.playerShieldTable )
    {
        if ( shield == wall ) { owner = player; break }
    }

    if ( !IsValid( owner ) )
        return false

    vector forward     = AnglesToForward( < 0, owner.EyeAngles().y, 0 > )
    vector incomingDir = Normalize( owner.GetOrigin() - attacker.GetOrigin() )

    return DotProduct( forward, incomingDir ) > 0.0
}

// ================================================================================================
//  COMPATIBILITY STUB
// ================================================================================================
int function GetAmpedWallsActiveCountForPlayer( entity player )
{
    if ( player in file.playerShieldTable )
        if ( IsValid( file.playerShieldTable[ player ] ) )
            return 1
    return 0
}

#endif
