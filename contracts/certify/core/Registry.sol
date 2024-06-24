// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import '@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol';
import '@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol';
import 'solady/src/tokens/ERC20.sol';
import './Anchor.sol';
import './interfaces/IRegistry.sol';
import './libraries/Errors.sol';
import './libraries/Native.sol';
import './libraries/Transfer.sol';

contract Registry is
	Initializable,
	AccessControlUpgradeable,
	Errors,
	Native,
	Transfer,
	IRegistry
{
	/// =========================
	/// === Storage Variables ===
	/// =========================

	// TODO: I have those mappings names
	mapping(address => bool) public accountAuthorizedToBeOwnerProfile;
	mapping(address => bytes32) public anchorToProfileId;
	mapping(bytes32 => Profile) public profilesToId;
	mapping(bytes32 => address) public profileIdToPendingOwner;

	bytes32 public constant CERTIFY_OWNER = keccak256('CERTIFY_OWNER');
	address public attestationProtocol;

	/// =========================
	/// ====== Initializer ======
	/// =========================

	function initialize(
		address _owner,
		address _attestationProtocol
	) external reinitializer(1) {
		if (_owner == address(0)) revert ZERO_ADDRESS();
		if (_attestationProtocol == address(0)) revert ZERO_ADDRESS();

		_updateAttestationProtocol(_attestationProtocol);

		_grantRole(CERTIFY_OWNER, _owner);
	}

	/// =========================
	/// ======= Modifiers =======
	/// =========================

	modifier onlyAccountAuthorizedToBeOwnerProfile(address _account) {
		if (!accountAuthorizedToBeOwnerProfile[_account]) revert UNAUTHORIZED();
		_;
	}

	modifier onlyAttesterProtocol() {
		if (msg.sender != attestationProtocol) revert UNAUTHORIZED();
		_;
	}

	modifier onlyProfileOwner(bytes32 _profileId) {
		_checkOnlyProfileOwner(_profileId);
		_;
	}

	/// ==========================
	/// ===== View Functions =====
	/// ==========================

	function getAttestationProtocol() external view returns (address) {
		return attestationProtocol;
	}

	function getProfileByAnchor(
		address _anchor
	) external view returns (Profile memory) {
		bytes32 profileId = anchorToProfileId[_anchor];
		return profilesToId[profileId];
	}

	function getProfileById(
		bytes32 _profileId
	) external view returns (Profile memory) {
		return profilesToId[_profileId];
	}

	function isAuthorizedToCreateProfile(
		address _account
	) external view returns (bool) {
		return _isAuthorizedToCreateProfile(_account);
	}

	function isMemberOfProfile(
		bytes32 _profileId,
		address _member
	) external view returns (bool) {
		return _isMemberOfProfile(_profileId, _member);
	}

	function isOwnerOfProfile(
		bytes32 _profileId,
		address _owner
	) external view returns (bool) {
		return _isOwnerOfProfile(_profileId, _owner);
	}

	function isOwnerOrMemberOfProfile(
		bytes32 _profileId,
		address _account
	) external view returns (bool) {
		return
			_isOwnerOfProfile(_profileId, _account) ||
			_isMemberOfProfile(_profileId, _account);
	}

	/// =================================
	/// == External / Public Functions ==
	/// =================================

	function acceptProfileOwnership(bytes32 _profileId) external {
		Profile storage profile = profilesToId[_profileId];

		address newOwner = profileIdToPendingOwner[_profileId];

		if (msg.sender != newOwner) revert NOT_PENDING_OWNER();

		profile.owner = newOwner;
		delete profileIdToPendingOwner[_profileId];

		emit ProfileOwnerUpdated(_profileId, profile.owner);
	}

	function addMembers(
		bytes32 _profileId,
		address[] memory _members
	) external onlyProfileOwner(_profileId) {
		uint256 memberLength = _members.length;

		for (uint256 i; i < memberLength; ) {
			address member = _members[i];

			if (member == address(0)) revert ZERO_ADDRESS();

			_grantRole(_profileId, member);
			unchecked {
				++i;
			}
		}
	}

	function authorizeProfileCreation(
		address _account,
		bool _status
	) external onlyRole(CERTIFY_OWNER) {
		if (_account == address(0)) revert ZERO_ADDRESS();
		accountAuthorizedToBeOwnerProfile[_account] = _status;
		emit AccountAuthorizedToCreateProfile(_account, _status);
	}

	function createProfile(
		uint64 _attestationId,
		uint256 _nonce,
		string memory _name,
		address _owner,
		address[] memory _members
	) external onlyRole(CERTIFY_OWNER) {
		accountAuthorizedToBeOwnerProfile[_owner] = true;
		_createProfile(_attestationId, _nonce, _name, _owner, _members);
	}

	// This function is called by the attestor contract

	function didReceiveAttestation(
		address _attester,
		uint64,
		uint64 attestationId,
		bytes calldata extraData
	) external payable onlyAttesterProtocol {
		(uint256 nouce, string memory name, address[] memory members) = abi.decode(
			extraData,
			(uint256, string, address[])
		);

		_createProfile(attestationId, nouce, name, _attester, members);
	}

	function recoverFunds(
		address _token,
		address _recipient
	) external onlyRole(CERTIFY_OWNER) {
		if (_recipient == address(0)) revert ZERO_ADDRESS();

		uint256 amount = _token == NATIVE
			? address(this).balance
			: ERC20(_token).balanceOf(address(this));
		_transferAmount(_token, _recipient, amount);
	}

	function removeMembers(
		bytes32 _profileId,
		address[] memory _members
	) external onlyProfileOwner(_profileId) {
		uint256 memberLength = _members.length;

		for (uint256 i; i < memberLength; ) {
			_revokeRole(_profileId, _members[i]);
			unchecked {
				++i;
			}
		}
	}

	function updateAttestationProtocol(
		address _attestationProtocol
	) external onlyRole(CERTIFY_OWNER) {
		if (_attestationProtocol == address(0)) revert ZERO_ADDRESS();
		_updateAttestationProtocol(_attestationProtocol);
	}

	function updateProfileName(
		bytes32 _profileId,
		string memory _name
	) external onlyProfileOwner(_profileId) returns (address anchor) {
		anchor = _generateAnchor(_profileId, _name);

		Profile storage profile = profilesToId[_profileId];

		profile.name = _name;

		anchorToProfileId[profile.anchor] = bytes32(0);

		profile.anchor = anchor;
		anchorToProfileId[anchor] = _profileId;

		emit ProfileNameUpdated(_profileId, _name, anchor);

		return anchor;
	}

	function updateProfilePendingOwner(
		bytes32 _profileId,
		address _pendingOwner
	) external onlyProfileOwner(_profileId) {
		profileIdToPendingOwner[_profileId] = _pendingOwner;

		emit ProfilePendingOwnerUpdated(_profileId, _pendingOwner);
	}

	/// =========================
	/// == Internal Functions ===
	/// =========================

	function _checkOnlyProfileOwner(bytes32 _profileId) internal view {
		if (!_isOwnerOfProfile(_profileId, msg.sender)) revert UNAUTHORIZED();
	}

	function _createProfile(
		uint64 _attestationId,
		uint256 _nonce,
		string memory _name,
		address _owner,
		address[] memory _members
	) internal onlyAccountAuthorizedToBeOwnerProfile(_owner) returns (bytes32) {
		bytes32 profileId = _generateProfileId(_nonce, _owner);

		if (profilesToId[profileId].anchor != address(0))
			revert NONCE_NOT_AVAILABLE();

		if (_owner == address(0)) revert ZERO_ADDRESS();

		Profile memory profile = Profile({
			attestationId: _attestationId,
			id: profileId,
			nonce: _nonce,
			name: _name,
			owner: _owner,
			anchor: _generateAnchor(profileId, _name)
		});

		profilesToId[profileId] = profile;
		anchorToProfileId[profile.anchor] = profileId;

		uint256 memberLength = _members.length;
		bool isAuthorized = _isAuthorizedToCreateProfile(_owner);

		if (memberLength > 0 && !isAuthorized) {
			revert UNAUTHORIZED();
		}

		accountAuthorizedToBeOwnerProfile[_owner] = false;

		for (uint256 i; i < memberLength; ) {
			address member = _members[i];

			if (member == address(0)) revert ZERO_ADDRESS();

			_grantRole(profileId, member);
			unchecked {
				++i;
			}
		}

		emit ProfileCreated(
			profile.attestationId,
			profile.id,
			profile.nonce,
			profile.name,
			profile.owner,
			profile.anchor
		);

		return profileId;
	}

	function _generateAnchor(
		bytes32 _profileId,
		string memory _name
	) internal returns (address anchor) {
		bytes memory encodedData = abi.encode(_profileId, _name);
		bytes memory encodedConstructorArgs = abi.encode(_profileId, address(this));

		bytes memory bytecode = abi.encodePacked(
			type(Anchor).creationCode,
			encodedConstructorArgs
		);

		bytes32 salt = keccak256(encodedData);

		address preComputedAddress = address(
			uint160(
				uint256(
					keccak256(
						abi.encodePacked(
							bytes1(0xff),
							address(this),
							salt,
							keccak256(bytecode)
						)
					)
				)
			)
		);

		// Try to deploy the anchor contract, if it fails then the anchor already exists
		try new Anchor{salt: salt}(_profileId, address(this)) returns (
			Anchor _anchor
		) {
			anchor = address(_anchor);
		} catch {
			if (Anchor(payable(preComputedAddress)).profileId() != _profileId)
				revert ANCHOR_ERROR();
			anchor = preComputedAddress;
		}
	}

	function _generateProfileId(
		uint256 _nonce,
		address _owner
	) internal pure returns (bytes32) {
		return keccak256(abi.encodePacked(_nonce, _owner));
	}

	function _isAuthorizedToCreateProfile(
		address _account
	) internal view returns (bool) {
		return accountAuthorizedToBeOwnerProfile[_account];
	}

	function _isMemberOfProfile(
		bytes32 _profileId,
		address _member
	) internal view returns (bool) {
		return hasRole(_profileId, _member);
	}

	function _isOwnerOfProfile(
		bytes32 _profileId,
		address _owner
	) internal view returns (bool) {
		return profilesToId[_profileId].owner == _owner;
	}

	function _updateAttestationProtocol(address _attestationProtocol) internal {
		attestationProtocol = _attestationProtocol;
	}
}
