untyped

// ================================================================================================
//  JIXIE'S A-BRAWL MOD  —  mp_weapon_deployable_cover.nut
//
//  ARCHITECTURE OVERVIEW
//  ─────────────────────
//  The "shield" is made of two distinct layers:
//
//    1. COLLISION ENTITY  ("wall")
//       An invisible prop_dynamic using the stock amped-wall model.
//       It exists purely to receive damage callbacks and to provide a
//       world-space anchor for the particle FX.  Rendered invisible via Hide().
//
//    2. VISUAL LAYER  ("domeFX")
//       A particle effect started on the collision entity using
//       StartParticleEffectOnEntity(..., FX_PATTACH_ABSORIGIN_FOLLOW, -1).
//       Control Point 1 carries <scale, scale, scale> so the dome can be
//       resized at runtime via the a_brawl_dome_scale ConVar.
//
//  Both layers are repositioned every frame by HeldShield_PositionThread.
//
//  LIFECYCLE
//  ─────────
//    Activate  → OnWeaponTossReleaseAnimEvent → CreateHeldAmpedWall
//    Re-press  → OnWeaponAttemptOffhandSwitch → DestroyHeldAmpedWall → false
//    HP = 0    → OnAmpedWallDamaged           → DestroyHeldAmpedWall
//    Death     → lifetime thread OnThreadEnd  → DestroyHeldAmpedWall
//    Duration  → lifetime thread wait         → DestroyHeldAmpedWall
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

global function CreateScaledDome
global function AttachScaledFX
global function SpawnDomeShield
#endif

// ── Asset identifiers ─────────────────────────────────────────────────────────
//
//  DEPLOYABLE_SHIELD_MODEL is used for the invisible collision entity.
//  The engine needs a valid model on any prop_dynamic, but we Hide() it
//  so only the particle FX is visible.
//
//  DOME_FX_NAME must match the `particle "..."` name in awall_dome_fx.pdef exactly.
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
const int   DEFAULT_SHIELD_HEALTH   = 850
const float DEFAULT_FORWARD_OFFSET  = 50.0
const float DEFAULT_VERTICAL_OFFSET = 0.0
const float DEFAULT_DOME_SCALE      = 0.35
const vector AWALL_ORANGE = <1.0, 0.45, 0.0>

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
    print( "[A-Brawl] bubbleFXIndex = " + string( file.bubbleFXIndex ) )

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
    // print( "[A-Brawl] bubbleFXIndex = " + string( file.bubbleFXIndex ) )
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
        // CreateHeldAmpedWall( owner )
        SpawnDomeShield( owner )
    #endif

    return 0
}


// ================================================================================================
//  CREATE HELD AMPED WALL  (SERVER ONLY)
// ================================================================================================
#if SERVER

entity function CreateScaledDome( entity owner, vector origin, float domeScale, vector domeColor )
{
    entity dome = CreateEntity( "prop_dynamic" )
    dome.SetValueForModelKey( $"models/fx/xo_shield.mdl" )

    // Basic KV setup
    dome.kv.solid = SOLID_VPHYSICS
    dome.kv.rendercolor = format( "%d %d %d", int(domeColor.x * 255), int(domeColor.y * 255), int(domeColor.z * 255) )
    dome.kv.modelscale = domeScale.tostring()

    dome.SetOrigin( origin )
    dome.SetAngles( <0,0,0> )

    DispatchSpawn( dome )

    // Optional: parent to owner (or wall, or ability entity)
    if ( owner != null )
        dome.SetParent( owner )

    return dome
}

entity function AttachScaledFX( entity ownerEnt, vector origin, float domeScale, vector fxColor )
{

    int fxIndex = PrecacheParticleSystem( DOME_FX_NAME )
    if ( fxIndex == 0 )
    {
        print( "[A-Brawl] ERROR: FX not found: " + DOME_FX_NAME )
        return null
    }

    entity fx = StartParticleEffectInWorld_ReturnEntity(
        fxIndex,
        origin,
        <0,0,0>
    )

    // Color (if supported)
    EffectSetControlPointVector( fx, 1, fxColor )

    // Scale (if supported)
    EffectSetControlPointVector( fx, 2, <domeScale, domeScale, domeScale> )

    fx.DisableHibernation()
    fx.SetParent( ownerEnt )

    return fx
}

void function SpawnDomeShield( entity owner )
{
    float domeScale = 0.5
    vector domeColor = <1, 0.40, 0> // orange

    vector origin = owner.GetOrigin() + <0,0,25>

    entity domeModel = CreateScaledDome( owner, origin, domeScale, domeColor )

    // Optional FX layer
    entity domeFX = AttachScaledFX( domeModel, origin, domeScale, domeColor )
}

void function CreateHeldAmpedWall( entity player )
{


    // if ( !file.initHasBeenCalledOnce )
    // {
    //     PrecacheModel( DOME_SHIELD_MODEL )
    //     file.bubbleFXIndex = PrecacheParticleSystem( DOME_FX_NAME )
    //     print( "[A-Brawl] bubbleFXIndex = " + string( file.bubbleFXIndex ) )

    //     file.initHasBeenCalledOnce = true
    // }

    if ( !IsValid( player ) )
        return

    // Safety: destroy any pre-existing shield.
    if ( player in file.playerShieldTable )
    {
        entity old = file.playerShieldTable[ player ]
        if ( IsValid( old ) )
            DestroyHeldAmpedWall( player )
    }

    // ── ConVar reads ──────────────────────────────────────────────────────────
    int   health    = GetConVarInt( "a_brawl_shield_health" )
    if ( health <= 0 ) health = DEFAULT_SHIELD_HEALTH

    float fwdOffset = GetConVarFloat( "a_brawl_shield_forward_offset" )
    float upOffset  = GetConVarFloat( "a_brawl_shield_vertical_offset" )
    float duration  = GetConVarFloat( "a_brawl_shield_duration" )
    float domeScale = GetConVarFloat( "a_brawl_dome_scale" )

    // a_brawl_dome_scale sets CP1 on the dome particle.
    // 1.0 → native OBJ size (radius ≈ 50 units).
    // 1.5 → 75 unit radius, etc.
    if ( domeScale <= 0.0 ) domeScale = DEFAULT_DOME_SCALE

    // ── Spawn collision entity ────────────────────────────────────────────────
    //
    //  Mirroring _bubble_shield.gnut: use CreateEntity + SetValueForModelKey +
    //  DispatchSpawn rather than CreatePropDynamic.  This is the pattern Respawn
    //  uses for the production bubble shield and is more stable for this model.
    //
    entity wall = CreateEntity( "prop_dynamic" )
    wall.SetValueForModelKey( DOME_SHIELD_MODEL )

    // Solid enough for bullet traces, but NOT players — same flags as the original.
    wall.kv.solid          = SOLID_VPHYSICS
    wall.kv.CollisionGroup = TRACE_COLLISION_GROUP_BLOCK_WEAPONS_AND_PHYSICS

    // Start at the player's position; the positioning thread will take over.
    wall.SetOrigin( player.GetOrigin() )

    // ── ORIENTATION ──────────────────────────────────────────────────────────
    //
    //  xo_shield.mdl default orientation: dome cup opens UPWARD (Y-up in model space).
    //  We want it to open FORWARD (toward the enemy).
    //
    //  Rotating -90° in pitch tilts the top of the dome away from the player
    //  and the open face toward the player's forward direction:
    //
    //       Pitch  0  →  dome opens up   (normal Titan use)
    //       Pitch -90 →  dome opens forward  (what we want)
    //
    //  The positioning thread then overwrites angles every frame, applying
    //  < -90, eyeAngles.y, 0 > so the dome always faces horizontally forward.
    //
    wall.SetAngles( < -90, player.EyeAngles().y, 0 > )

    DispatchSpawn( wall )

    // Hide the stock model — the dome FX is the only visual.
    // wall.Hide()

    // ── Damage settings ───────────────────────────────────────────────────────
    wall.SetTakeDamageType( DAMAGE_YES )
    wall.SetDamageNotifications( true )
    wall.SetMaxHealth( GetConVarFloat("a_brawl_shield_health") )
    wall.SetHealth( GetConVarFloat("a_brawl_shield_health") )

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

    // Script-side HP pool.
    wall.s.health <- health

    AddEntityCallback_OnDamaged( wall, OnAmpedWallDamaged )

    // ── Register in lookup tables ─────────────────────────────────────────────
    file.playerShieldTable[ player ] <- wall

    // ── Spawn bubble-shield FX  (matching _bubble_shield.gnut pattern) ───────  //
    //
    //
    //  We use StartParticleEffectInWorld_ReturnEntity (same as the original) so
    //  we get back an entity handle we can parent + later destroy.
    //
    //  The FX origin is set 25 units above the wall origin to match the offset
    //  used in CreateBubbleShieldWithSettings.  After spawning, we parent each FX
    //  to the wall so it follows the positioning thread automatically.
    //
    array<entity> fxList = []

    vector fxOrigin = wall.GetOrigin() + Vector( 0, 0, 25 )
    if ( file.bubbleFXIndex != 0 )
    {
        // entity domeFX = StartParticleEffectInWorld_ReturnEntity(
        entity domeFX = StartParticleEffectInWorld_ReturnEntity(
            file.bubbleFXIndex,
            fxOrigin,
            <0,0,0>
        )

        // // CP1 = color
        // EffectSetControlPointVector( domeFX, 1, AWALL_ORANGE )

        // // CP2 = scale
        // EffectSetControlPointVector( domeFX, 2, < domeScale, domeScale, domeScale > )

        domeFX.DisableHibernation()
        domeFX.SetParent( wall )

        fxList.append( domeFX )

        file.wallFXTable[ wall ] <- fxList

        // ── Sound ─────────────────────────────────────────────────────────────────
        EmitSoundOnEntity( wall, SHIELD_START_SFX )

        // Wait until the player is fully alive and initialized
        while ( !IsValid( player ) || !IsAlive( player ) )
            WaitFrame()


        // ── Threads ───────────────────────────────────────────────────────────────
        thread HeldShield_PositionThread( wall, player, fwdOffset, upOffset )
        thread HeldShield_LifetimeThread( wall, player, duration )
    }
    else
    {
        print( "[A-Brawl] WARNING: bubbleFXIndex is 0, not spawning FX" )
    }
}


// ================================================================================================
//  POSITION THREAD
//
//  Locks the wall entity in front of the player every frame.
//  The dome FX is attached with FX_PATTACH_ABSORIGIN_FOLLOW, so it
//  rides along automatically without any extra code here.
//
//  Orientation notes:
//    • Pitch is zeroed — the dome stands upright in world space even when
//      the player aims up/down.  This gives consistent hemispherical coverage
//      without exposing the legs when aiming high.
//    • Yaw-only rotation means the flat face of the dome always faces the
//      direction the player is horizontally looking.
//    • Forward offset uses the full eye-angles forward vector so the shield
//      doesn't drift into walls when looking at steep angles.
//    • Change shieldAngles to < eyeAngles.x, eyeAngles.y, 0 > if you ever
//      want the dome to tilt with the player's pitch.
// ================================================================================================
void function HeldShield_PositionThread( entity wall, entity player, float fwdOffset, float upOffset )
{
    wall.EndSignal( "OnDestroy" )
    player.EndSignal( "OnDestroy" )

    while ( IsValid( wall ) && IsValid( player ) && IsAlive( player ) )
    {
        vector eyeAngles = player.EyeAngles()

        vector forward   = AnglesToForward( eyeAngles )
        vector worldUp   = < 0, 0, 1 >

        vector shieldOrigin = player.GetOrigin()
                              + forward * fwdOffset
                              + worldUp * upOffset

        vector shieldAngles = < eyeAngles.x - 90, eyeAngles.y, 0 >

        wall.SetOrigin( shieldOrigin )
        wall.SetAngles( shieldAngles )

        WaitFrame()   // crashed if wait 0
    }
}


// ================================================================================================
//  LIFETIME THREAD
//
//  OnThreadEnd is the guaranteed cleanup path regardless of how the thread exits
//  (duration elapsed, wall destroyed externally, player died/disconnected).
// ================================================================================================
void function HeldShield_LifetimeThread( entity wall, entity player, float duration )
{
    wall.EndSignal( "OnDestroy" )
    player.EndSignal( "OnDestroy" )

    OnThreadEnd(
        function() : ( player )
        {
            if ( IsValid( player ) )
                DestroyHeldAmpedWall( player )
        }
    )

    if ( duration > 0.0 )
        wait duration
    else
        WaitForever()
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