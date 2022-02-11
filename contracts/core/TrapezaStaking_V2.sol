// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.7.5;

import "./interfaces/IERC20.sol";
import "./interfaces/IsFIDL.sol";
import "./interfaces/IgFIDL.sol";
import "./interfaces/IStaking.sol";

import "./libraries/SafeMath.sol";
import "./libraries/SafeERC20.sol";

interface IDistributor {
  function distribute() external returns (bool);
}

contract TrapezaStaking_V2 {
  /* ========== DEPENDENCIES ========== */

  using SafeMath for uint256;
  using SafeERC20 for IERC20;
  using SafeERC20 for IsFIDL;
  using SafeERC20 for IgFIDL;
  using SafeERC20 for IStaking;

  /* ========== EVENTS ========== */

  event DistributorSet(address distributor);
  event WarmupSet(uint256 warmup);

  /* ========== DATA STRUCTURES ========== */

  struct Epoch {
    uint256 length; // in seconds
    uint256 number; // since inception
    uint256 endBlock; // timestamp
    uint256 distribute; // amount
  }

  struct Claim {
    uint256 deposit; // if forfeiting
    uint256 gons; // staked balance
    uint256 expiry; // end of warmup period
    bool lock; // prevents malicious delays for claim
  }

  /* ========== STATE VARIABLES ========== */

  IERC20 public immutable FIDL;
  IsFIDL public immutable sFIDL;
  IgFIDL public immutable gFIDL;

  address public oldStaking;

  Epoch public epoch;

  IDistributor public distributor;

  mapping(address => Claim) public warmupInfo;
  uint256 public warmupPeriod;
  uint256 private gonsInWarmup;

  /* ========== CONSTRUCTOR ========== */

  constructor(
    address _FIDL,
    address _sFIDL,
    address _gFIDL,
    address _oldStaking,
    uint256 _oldEpochNumber,
    uint256 _oldEpochBlock
  ) {
    require(_FIDL != address(0), "Zero address: FIDL");
    FIDL = IERC20(_FIDL);

    require(_sFIDL != address(0), "Zero address: sFIDL");
    sFIDL = IsFIDL(_sFIDL);

    require(_gFIDL != address(0), "Zero address: gFIDL");
    gFIDL = IgFIDL(_gFIDL);

    require(_oldStaking != address(0), "Zero address: old staking");
    oldStaking = _oldStaking;

    epoch = Epoch({
      length: 9600,
      number: _oldEpochNumber,
      endBlock: _oldEpochBlock - 9600,
      distribute: 0
    });
  }

  /* ========== MUTATIVE FUNCTIONS ========== */

  /**
   * @notice stake FIDL to enter warmup
   * @param _to address
   * @param _amount uint
   * @param _claim bool
   * @return uint
   */
  function stake(
    address _to,
    uint256 _amount,
    bool _claim
  ) external returns (uint256) {
    rebase();

    FIDL.safeTransferFrom(msg.sender, address(this), _amount);

    if (_claim && warmupPeriod == 0) {
      return _send(_to, _amount);
    } else {
      Claim memory info = warmupInfo[_to];

      if (!info.lock) {
        require(_to == msg.sender, "External deposits for account are locked");
      }

      warmupInfo[_to] = Claim({
        deposit: info.deposit.add(_amount),
        gons: info.gons.add(sFIDL.gonsForBalance(_amount)),
        expiry: epoch.number.add(warmupPeriod),
        lock: info.lock
      });

      gonsInWarmup = gonsInWarmup.add(sFIDL.gonsForBalance(_amount));

      return _amount;
    }
  }

  /**
   * @notice retrieve stake from warmup
   * @param _to address
   * @return uint
   */
  function claim(address _to) public returns (uint256) {
    Claim memory info = warmupInfo[_to];

    if (!info.lock) {
      require(_to == msg.sender, "External claims for account are locked");
    }

    if (epoch.number >= info.expiry && info.expiry != 0) {
      delete warmupInfo[_to];

      gonsInWarmup = gonsInWarmup.sub(info.gons);

      return _send(_to, sFIDL.balanceForGons(info.gons));
    }

    return 0;
  }

  /**
   * @notice forfeit stake and retrieve FIDL
   * @return uint
   */
  function forfeit() external returns (uint256) {
    Claim memory info = warmupInfo[msg.sender];
    delete warmupInfo[msg.sender];

    gonsInWarmup = gonsInWarmup.sub(info.gons);

    FIDL.safeTransfer(msg.sender, info.deposit);

    return info.deposit;
  }

  /**
   * @notice prevent new deposits or claims from ext. address (protection from malicious activity)
   */
  function toggleLock() external {
    warmupInfo[msg.sender].lock = !warmupInfo[msg.sender].lock;
  }

  /**
   * @notice redeem sFIDL for FIDLs
   * @param _to address
   * @param _amount uint
   * @param _rebasing bool
   * @return amount_ uint256
   */
  function unstake(
    address _to,
    uint256 _amount,
    bool _rebasing
  ) external returns (uint256 amount_) {
    if (_rebasing) {
      rebase();
    }

    gFIDL.burn(msg.sender, _amount); // amount was given in gFIDL terms
    amount_ = gFIDL.balanceFrom(_amount);

    require(
      amount_ <= FIDL.balanceOf(address(this)),
      "Insufficient FIDL balance in contract"
    );

    FIDL.safeTransfer(_to, amount_);
  }

  /**
   * @notice trigger rebase if epoch over
   */
  function rebase() public {
    if (epoch.endBlock <= block.number) {
      sFIDL.rebase(epoch.distribute, epoch.number);

      epoch.endBlock = epoch.endBlock.add(epoch.length);
      epoch.number++;

      if (address(distributor) != address(0)) {
        distributor.distribute();
      }

      uint256 balance = FIDL.balanceOf(address(this)).add(
        FIDL.balanceOf(oldStaking)
      );
      uint256 staked = sFIDL.circulatingSupply();

      if (balance <= staked) {
        epoch.distribute = 0;
      } else {
        epoch.distribute = balance.sub(staked);
      }
    }
  }

  /* ========== INTERNAL FUNCTIONS ========== */

  /**
   * @notice send staker their amount as sFIDL or gFIDL
   * @param _to address
   * @param _amount uint256
   */
  function _send(address _to, uint256 _amount) internal returns (uint256) {
    gFIDL.mint(_to, gFIDL.balanceTo(_amount)); // send as gFIDL (convert units from FIDL)
    return gFIDL.balanceTo(_amount);
  }

  /* ========== VIEW FUNCTIONS ========== */

  /**
   * @notice returns the sFIDL index, which tracks rebase growth
   * @return uint256
   */
  function index() public view returns (uint256) {
    return sFIDL.index();
  }

  /**
   * @notice total supply in warmup
   * @return uint256
   */
  function supplyInWarmup() public view returns (uint256) {
    return sFIDL.balanceForGons(gonsInWarmup);
  }

  /* ========== MANAGERIAL FUNCTIONS ========== */

  /**
   * @notice sets the contract address for LP staking
   * @param _distributor address
   */
  function setDistributor(address _distributor) external {
    distributor = IDistributor(_distributor);
    emit DistributorSet(_distributor);
  }

  /**
   * @notice set warmup period for new stakers
   * @param _warmupPeriod uint
   */
  function setWarmupLength(uint256 _warmupPeriod) external {
    warmupPeriod = _warmupPeriod;
    emit WarmupSet(_warmupPeriod);
  }
}
