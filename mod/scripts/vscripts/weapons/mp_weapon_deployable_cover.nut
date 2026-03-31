untyped

// ======================================================================================================
//  JIXIE'S A-BRAWL MOD
//  Changes the A-Wall ability from a deploayable cover to a personal shield that stays with the player.
// ======================================================================================================

global function MpWeaponDeployableCover_Init

global function OnWeaponTossPrep_weapon_deployable_cover
global function OnWeaponTossReleaseAnimEvent_weapon_deployable_cover
global function OnWeaponAttemptOffhandSwitch_weapon_deployable_cover

#if SERVER
global function CreateHeldAmpedWall
global function DestroyHeldAmpedWall
global function OnAmpedWallDamaged
global function FlashShieldHit
global function GetAmpedWallsActiveCountForPlayer
global function HeldShield_ShouldBlockDamage
global function CreateScaledDome
global function AttachScaledFX
#endif

// ── Asset identifiers ─────────────────────────────────────────────────────────
//
//  DEPLOYABLE_SHIELD_MODEL is used for the invisible collision entity.
//  The engine needs a valid model on any prop_dynamic, but we Hide() it
//  so only the particle FX is visible.
//

// const DEPLOYABLE_SHIELD_MODEL = $"models/fx/pilot_shield_wall_amped.mdl"
const DOME_SHIELD_MODEL = $"models/fx/xo_shield.mdl"
const asset DOME_FX_NAME = $"awall_dome_fx"

// Stock A-Wall sounds / break FX reused for now.
const SHIELD_BREAK_FX  = $"P_pilot_amped_shield_break"
const SHIELD_START_SFX = "Hardcover_Shield_Start_3P"
const SHIELD_END_SFX   = "Hardcover_Shield_End_3P"
const SHIELD_HIT_SFX = "Hardcover_Shield_Hit_3P"

// ── Hardcoded fallbacks (ConVars override at runtime) ─────────────────────────
const int   DEFAULT_SHIELD_HEALTH   = 100
const float DEFAULT_FORWARD_OFFSET  = 50.0
const float DEFAULT_VERTICAL_OFFSET = 0.0
const float DEFAULT_DOME_SCALE      = 0.35
const vector SHIELD_COLOR = <1.0, 0.45, 0.0>

// ── File-scope state ──────────────────────────────────────────────────────────
struct
{
    // player → active wall collision entity
    table< entity, entity > playerShieldTable

    // wall entity → its running dome FX entity (for clean teardown)
    table< entity, array<entity> > wallFXTable

    // int precachedDomeFX
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
    // file.bubbleFXIndex = GetParticleSystemIndex( DOME_FX_NAME )

    if (file.bubbleFXIndex == 0 ) {
        print( "[A-Brawl] WARNING: FX not found: " + DOME_FX_NAME )
    } else {
        print( "[A-Brawl] bubbleFXIndex = " + string( file.bubbleFXIndex ) )
    }

    file.initHasBeenCalledOnce = true
    #endif
}

// ================================================================================================
//  INIT
// ================================================================================================
function MpWeaponDeployableCover_Init()
{
    // PrecacheModel( DOME_SHIELD_MODEL )
    // file.bubbleFXIndex = PrecacheParticleSystem( DOME_FX_NAME )
    // // print( "[A-Brawl] precached dome FX = " + string( file.precachedDomeFX ) )
    // print( "[A-Brawl                 ] bubbleFXIndex = " + string( file.bubbleFXIndex ) )
}

// ================================================================================================
//  OFFHAND SWITCH GATE
//  No shield active  -> return true  (let the deploy animation play)
//  Shield active     -> destroy it, return false (silently eat the button press)
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
            DestroyHeldAmpedWall( player )
            return false
        }
        // Stale entry from a shield that was already broken — clean up and allow redeploy.
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
    // Empty — add a "readying" sound here if desired.
}


// ================================================================================================
//  TOSS RELEASE ANIM EVENT
//  Intercepts the throw keyframe and spawns the held shield instead.
//  Returns 0 → no ammo consumed.
// ================================================================================================
var function OnWeaponTossReleaseAnimEvent_weapon_deployable_cover( entity weapon, WeaponPrimaryAttackParams attackParams )
{
    #if SERVER
    entity owner = weapon.GetWeaponOwner()
    if ( IsValid( owner ) )
        CreateHeldAmpedWall( owner )
        // SpawnDomeShield( owner )
    #endif

    return 0
}


// ================================================================================================
//  CREATE HELD AMPED WALL  (SERVER ONLY)
// ================================================================================================
#if SERVER

// Visual Dome Model Layer
// entity function CreateScaledDome( entity owner, entity player, float domeScale, vector domeColor )
entity function CreateScaledDome( entity wall, float domeScale, vector domeColor )
{
    entity dome = CreateEntity( "prop_dynamic" )
    dome.SetValueForModelKey( DOME_SHIELD_MODEL )

    // Basic KV setup
    dome.kv.solid = 0
    dome.kv.CollisionGroup = TRACE_COLLISION_GROUP_NONE

    dome.kv.rendercolor = format(
        "%d %d %d",
        int(domeColor.x * 255),
        int(domeColor.y * 255),
        int(domeColor.z * 255)
    )
    dome.kv.modelscale = domeScale.tostring()
    dome.kv.renderamt = 255
    dome.kv.renderfx = 0
    dome.kv.rendermode = 5   // additive

    StartParticleEffectOnEntity( dome, GetParticleSystemIndex( $"P_bubble_shield" ), FX_PATTACH_ABSORIGIN_FOLLOW, -1 )

    DispatchSpawn( dome )

    dome.SetParent( wall )
    dome.SetLocalOrigin( < 0, 0, 0 > )
    dome.SetLocalAngles( < 0, 0, 0 > )

    return dome
}

// FX Layer ** Unused because I could not get it to not crash my game
//            (likely a problem with the precached file being invalid)
entity function AttachScaledFX( entity wall, float domeScale, vector fxColor )
{
    print( "[A-Brawl] AttachScaledFX CALLED" )

    if ( file.bubbleFXIndex == 0 )
    {
        print( "[A-Brawl] ERROR: FX not found: " + DOME_FX_NAME )
        return null
    }

    // Delay until wall is fully spawned
    thread function() : ( wall, domeScale, fxColor )
    {
        WaitFrame()

        if ( !IsValid( wall ) )
            return

        entity fx = StartParticleEffectInWorld_ReturnEntity(
            file.bubbleFXIndex,
            wall.GetOrigin() + <0,0,0>,
            <0,0,0>
        )

        EffectSetControlPointVector( fx, 1, fxColor )
        EffectSetControlPointVector( fx, 2, <domeScale, domeScale, domeScale> )

        fx.DisableHibernation()
        fx.SetParent( wall )
    }()

    /*
    if ( file.bubbleFXIndex == 0 )
    {
        print( "[A-Brawl] ERROR: FX not precached: " + DOME_FX_NAME )
        return null
    }

    entity fx = StartParticleEffectOnEntity( wall, file.bubbleFXIndex, FX_PATTACH_ABSORIGIN_FOLLOW, -1 )
    if ( IsValid( fx ) )
    {
        EffectSetControlPointVector( fx, 1, < domeScale, domeScale, domeScale > )
        fx.DisableHibernation()
    }
    return fx
    */
}

// Main Shield Logic
void function CreateHeldAmpedWall( entity player )
{
    if ( !IsValid( player ) )
        return

    EnsureShieldFXPrecached()

    // Safety: destroy any pre-existing shield.
    if ( player in file.playerShieldTable )
    {
        entity old = file.playerShieldTable[ player ]
        if ( IsValid( old ) )
            DestroyHeldAmpedWall( player )
    }

    // ConVar reads
    int   health    = GetConVarInt( "a_brawl_shield_health" )
    if ( health <= 0 ) health = DEFAULT_SHIELD_HEALTH

    float fwdOffset  = GetConVarFloat( "a_brawl_shield_forward_offset" )
    float upOffset   = GetConVarFloat( "a_brawl_shield_vertical_offset" )
    float sideOffset = GetConVarFloat( "a_brawl_shield_side_offset" )
    float duration   = GetConVarFloat( "a_brawl_shield_duration" )
    float cd         = GetConVarFloat( "a_brawl_shield_cooldown" )
    float domeScale  = GetConVarFloat( "a_brawl_dome_scale" )
    bool domeHide    = GetConVarBool( "a_brawl_shield_hide" )

    // float endTime = Time() + cd

    // player.s.nextShieldUseTime = endTime

    // player.SetPlayerNetFloat( "tactical_cooldown_start", Time() )
    // player.SetPlayerNetFloat( "tactical_cooldown_end", endTime )
    // player.SetPlayerNetFloat( "tactical_cooldown_duration", cd )

    if ( domeScale <= 0.0 )
        domeScale = DEFAULT_DOME_SCALE

    entity wall = CreateEntity( "prop_dynamic" )
    wall.SetValueForModelKey( DOME_SHIELD_MODEL )
    wall.kv.modelscale = domeScale.tostring()
    wall.kv.solid          = SOLID_VPHYSICS
    wall.kv.CollisionGroup = TRACE_COLLISION_GROUP_BLOCK_WEAPONS_AND_PHYSICS
    DispatchSpawn( wall )
    wall.SetOwner( player )
    if ( domeHide ) wall.Hide()

    wall.SetParent( player )
    wall.SetLocalOrigin( < fwdOffset, sideOffset, upOffset > )
    int wallX = GetConVarInt( "a_brawl_shield_rotate_x" )
    int wallY = GetConVarInt( "a_brawl_shield_rotate_y" )
    int wallZ = GetConVarInt( "a_brawl_shield_rotate_z" )
    // wall.SetLocalAngles( < wallX, wallY, wallZ > )

    // Damage settings
    wall.SetTakeDamageType( DAMAGE_YES )
    wall.SetDamageNotifications( true )
    wall.SetMaxHealth( health )
    wall.SetHealth( health )

    // Amped-wall pass-through: amps friendly bullets crossing the shield face.
    wall.SetPassThroughFlags( PTF_ADDS_MODS | PTF_NO_DMG_ON_PASS_THROUGH )
    wall.SetPassThroughThickness( 0 )
    wall.SetPassThroughDirection( -0.55 )   // same as original DeployAmpedWall
    wall.SetBlocksRadiusDamage( true )
    wall.kv.contents = ( int( wall.kv.contents ) | CONTENTS_NOGRAPPLE )  // match bubble shield

    if ( duration > 0.0 )
        StatusEffect_AddTimed( wall, eStatusEffect.pass_through_amps_weapon, 1.0, duration, 0.0 )
    else
        StatusEffect_AddTimed( wall, eStatusEffect.pass_through_amps_weapon, 1.0, 1, 0.0 )  // 1 second base, in case duration is bad

    SetTeam( wall, TEAM_BOTH )
    wall.s.health <- health
    AddEntityCallback_OnDamaged( wall, OnAmpedWallDamaged )

    // Register in lookup tables
    file.playerShieldTable[ player ] <- wall

    // Visual dome + FX
    // entity domeModel = CreateScaledDome( wall, player, domeScale, SHIELD_COLOR )
    entity domeModel = CreateScaledDome( wall, domeScale, SHIELD_COLOR )
    // Dont do fx because it is unnecessary and does not work because of probably the file that it is trying to use in the precache.
    // entity domeFX = AttachScaledFX( wall, domeScale, SHIELD_COLOR )

    thread HeldShield_LifetimeThread( wall, player, duration )
    thread HeldShield_DirectionThread( wall, player )

    // Old positioning thread
    // thread HeldShield_PositionThread( wall, player, fwdOffset, upOffset )

    EmitSoundOnEntity( wall, SHIELD_START_SFX)
}

void function HeldShield_DirectionThread( entity wall, entity player)
{
    wall.EndSignal( "OnDestroy" )
    player.EndSignal( "OnDestroy" )

    while ( true )
    {
        vector ang = player.EyeAngles()

        wall.SetLocalAngles( < 90, 0, 0 > )

        WaitFrame()
    }
}

void function HeldShield_LifetimeThread( entity wall, entity player, float duration )
{
    // Safety: if either entity is invalid, bail immediately
    if ( ( !IsValid( wall ) || !IsValid( player ) || !IsAlive( player ) ) )
        return

    wall.EndSignal( "OnDestroy" )
    player.EndSignal( "OnDestroy" )

    OnThreadEnd(
        function() : ( wall, player )
        {
            if ( IsValid( wall ) )
                wall.Destroy()

            if ( IsValid( player ) )
                DestroyHeldAmpedWall( player )
        }
    )

    // Duration safety
    if ( duration <= 0.0 )
        duration = 9999.0

    wait duration
}


// ================================================================================================
//  DESTROY HELD AMPED WALL
//
//  Single authoritative cleanup.  Safe to call multiple times.
// ================================================================================================
void function DestroyHeldAmpedWall( entity player )
{
    if ( !IsValid( player ) )
        return

    if ( !( player in file.playerShieldTable ) )
        return

    entity wall = file.playerShieldTable[ player ]
    delete file.playerShieldTable[ player ]

    if ( IsValid( wall ) )
    {
        // Kill both FX entities cleanly.
        if ( wall in file.wallFXTable )
        {
            array<entity> fxList = file.wallFXTable[ wall ]
            delete file.wallFXTable[ wall ]
            foreach ( fx in fxList )
            {
                if ( IsValid( fx ) )
                    EffectStop( fx )   // matches how _bubble_shield.gnut tears down FX
            }
        }

        // Break effect and sound at the shield's last position.
        PlayFX( SHIELD_BREAK_FX, wall.GetOrigin(), wall.GetAngles() )
        EmitSoundAtPosition( TEAM_BOTH, wall.GetOrigin(), SHIELD_END_SFX )

        wall.Destroy()
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

    // A-Wall Damage Modifier
    float damage = DamageInfo_GetDamage( damageInfo )
    ShieldDamageModifier mod = GetShieldDamageModifier( damageInfo )
    damage *= mod.damageScale
    DamageInfo_SetDamage( damageInfo, damage )

    wall.s.health -= damage

    if ( wall.s.health <= 0 )
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

    // if ( "domeModel" in wall.s )
    // {
    //     var dome = null
    //     if ( "domeModel" in wall.s )
    //         dome = wall.s.domeModel
    //         if ( IsValid( dome ) )
    //             thread FlashShieldHit( dome )
    // }
}

void function FlashShieldHit( var dome )
{
    if ( !IsValid( dome ) )
        return

    // Boost brightness (renderamt 255 = fully bright)
    dome.kv.renderamt = 255
    dome.kv.rendercolor = "255 200 100"   // bright orange flash

    // Hold for a few frames
    WaitFrame()
    WaitFrame()

    // Restore original color
    vector c = SHIELD_COLOR
    dome.kv.rendercolor = format( "%d %d %d",
        int(c.x * 255),
        int(c.y * 255),
        int(c.z * 255)
    )
    dome.kv.renderamt = 255
}

// ================================================================================================
//  HEMISPHERE CHECK
//
//  Uses yaw-only forward to match the dome's visual orientation (which is also
//  yaw-only in the positioning thread).  This means the shield covers the same
//  180° arc that the dome mesh faces, making the visuals and the blocking logic
//  consistent.
//
//  To tighten coverage to a 90° cone: change > 0.0 to > 0.707
//  To keep full 180° hemisphere:      keep   > 0.0
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

    // Yaw-only forward to match the dome's orientation.
    vector forward    = AnglesToForward( < 0, owner.EyeAngles().y, 0 > )
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